#!/usr/bin/env python3
"""queue-dispatch.py — keep idle lanes fed from a DURABLE queue, with no orchestrator turn.

THE GAP THIS CLOSES (and it is stated in the code it replaces)
    turn-end.py auto-nudges WIP-IDLE lanes, and says why it stops there:
        "It does NOT touch DONE-IDLE -- choosing the next issue needs the
         lane->label->rank judgement the orchestrator holds"
    So the NEXT-WORK decision lived in an agent's context. If that session dies, lanes
    get "continue" nudges and nobody hands out the queue. AGENTS.md is explicit that this
    is not acceptable: "Operational state must not live only in an agent's context -- if the
    session dies, the threads die with it."

    This script moves that judgement into FILES:
        <state>/queues/LANE-ASSIGNMENTS.tsv   lane -> work class      (durable)
        <state>/queues/LANDABLE.tsv|REMEDY.tsv the work itself       (durable)
        <state>/queues/CLAIMS.tsv             atomic claims          (durable)
    A successor session (or this script on a timer) can then feed the fleet with no memory
    of any conversation.

DESIGN RULES, each one paid for by a measured failure
  * DONE-IDLE only. WIP-IDLE is turn-end.py's job (work in flight -> "continue").
    WEDGED is a diagnosis, WAITING-CHILD is work, UNBOUND means the pane cannot be
    attributed -- none of those get a message from here.
  * NEVER a protected lane. HANG and every DMeer lane are owner-managed; the denylist is
    enforced in code, not by hope.
  * DRY-RUN BY DEFAULT. `--apply` is required to send anything. An automatic dispatcher
    that cannot be inspected first is a foot-gun.
  * One item per lane per tick, one tick per cooldown window (default 15 min), so a lane
    that finishes fast cannot be buried in queued instructions.
  * The claim is ATOMIC and taken BEFORE the send. A claim without a delivery wastes one
    item; a delivery without a claim gives two lanes the same PR, which is the failure
    this fleet has already paid for twice.
  * Every send goes through safe-send.sh, which re-checks idleness at the moment of
    sending -- the verdict read can be seconds stale by the time we act on it.

USAGE
    python3 queue-dispatch.py                 # dry run: say what it WOULD do
    python3 queue-dispatch.py --apply         # actually dispatch
    python3 queue-dispatch.py --status        # assignments + queue counts only
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
STATE = os.path.join(HOME, ".pi", "agent", "state", "queues")
TMPD = os.path.join(HOME, ".pi", "agent", "state", "queues", "briefs")
ASSIGNMENTS = os.path.join(STATE, "LANE-ASSIGNMENTS.tsv")
COOLDOWN_DIR = os.path.join(STATE, "dispatch-cooldown")
LANE_STATUS = os.path.join(HOME, ".pi", "agent", "scripts", "lane-status.py")
SAFE_SEND = os.path.join(HOME, ".pi", "agent", "scripts", "safe-send.sh")
CLAIM = os.path.join(STATE, "claim.py")

# ── the real gh, resolved absolutely (never via PATH) ────────────────────────────
# Same defect class as beta-progress.py/merge-queue.py: `gh` on PATH resolves to the
# agent gh-shim, which refuses when it cannot find the real binary. Read-only queries
# do not need the shim (it guards admin landing), so resolve the binary directly.
# ⛔ BUT PREFER THE HARNESS'S OWN gh LAYER (#1988) WHEN ONE IS DEPLOYED. It is derived from `$O` —
# never from PATH. ⛔ THE LAYER then resolves the real gh by WALKING PATH, so "#1872 cannot come back"
# would be false (in a minimal environment the first `gh` on PATH can be a shim that refuses at
# runtime, rc=126, with `os.access` still passing). The pin is therefore passed THROUGH the layer
# below (`GH_REST_REAL_GH`/`GH_LIMIT_REAL_GH`): the binary #1872 chose, plus the layer.
# ⛔ NO ABSOLUTE HOME PATH: `~/bin/gh` is the binary #1872 pinned, and expanduser builds the same
# path without hard-coding another user's home in shipped code.
_GH_CANDIDATES = (os.path.expanduser("~/bin/gh"), "/opt/homebrew/bin/gh", "/usr/local/bin/gh")


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


# ⛔ THE LAYER MUST NOT SLEEP INSIDE THIS PROCESS (#1988). It may run inside a heartbeat pass or
# DETACHED (`nohup … &`, bounded by its own lock), but its gh reads are bounded at 60 s while the
# layer's first documented backoff is 60 s: an in-call wait alone consumes the whole budget, and the
# caller is killed before the layer can say why — a rate-limited box then reports UNKNOWN/STALL
# instead of the RATE-LIMITED verdict it can prove. NO_WAIT makes the layer record the limit and
# return at once, so this process's own deferral takes over. Inherited by every DESCENDANT of this
# process (including the `claim` calls below) — all parts of the same bounded dispatch step.
os.environ.setdefault("GH_LIMIT_NO_WAIT", "1")
REPO = "daniel-ospina/tortoise"


def pr_still_open(item: str):
    """Is the item's PR STILL OPEN? Asked at the MOMENT OF SENDING, not trusted from the queue.

    WHY, AND WHY HERE. A queue is a CACHE of a fact that changes: whether a PR is still
    pending. Both of this dispatcher's queues went stale in one afternoon and it handed real
    lanes two ALREADY-MERGED PRs -- #6389 (merged 02:11Z) and #5136 (merged 18:25Z). Each
    cost a landing lane a cycle and left a claim on nothing, which then took an AMBIGUOUS
    rc=4 send to notice. THE QUEUE CANNOT BE TRUSTED TO BE FRESH, and refreshing it is a
    race it always loses eventually (my own LANDABLE rebuild dropped #6389 and the next
    cycle still sent it, from the OTHER queue). So the freshness is checked at the only
    moment it matters -- immediately before a lane is asked to work.

    ONE call per candidate (the dispatcher sends 0-3 items per cycle), so the cost is
    bounded and paid only when something is actually about to be sent.

    RETURNS: 'OPEN' | 'MERGED' | 'CLOSED' | None (could NOT read it).

    None IS NOT "NOT OPEN". A failed read must never be spent as evidence of absence (the
    telemetry false-zero rule), so the caller proceeds with a loud warning rather than
    silently discarding a live item -- the LANE verifies independently anyway via the rail.
    """
    m = re.search(r"PR\s+(\d+)", item or "")
    if not m:
        return None
    pr = m.group(1)
    try:
        r = subprocess.run([GH, "pr", "view", pr, "--repo", REPO, "--json", "state",
                            "--jq", ".state"],
                           capture_output=True, text=True, errors="replace", timeout=60,
                           env={**os.environ, **GH_LAYER_ENV} if GH_LAYER_ENV else None)
    except Exception:
        return None
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return r.stdout.strip().upper()

# ── protected lanes: never dispatched to, whatever their verdict says ─────────────
# HANG is the owner's park lane; the DMeer lanes are the owner's own work.
PROTECTED = ("HANG", "DMeer", "DMer", "π - DMeer", "DMeer -")

# ⛔ THE PRIORITY RECORD IS ONLY TRUSTWORTHY WHILE FRESH: two dispatch intervals of the job that
# writes it (`com.tortoise.pr-doctor`, StartInterval 1200s), after which the measurement is a
# past state and must not gate anything.
PR_FIRST_MAX_AGE_S = 2400
# `STATE` here is the QUEUES dir; the dispatcher's verdict lives one level up.
PR_DOCTOR_STATE = os.path.join(HOME, ".pi", "agent", "state")
COOLDOWN_S = 15 * 60

# Hard wall-clock bound (seconds) for the ONE fleet read per pass. lane-status.py has no
# internal deadline, so this is the only stop between a stalled scan and an unbounded wait.
# Hitting it raises LaneReadError -> the pass ABORTS (exit 3); it is never an empty fleet.
#
# WHY 600 AND NOT TIGHTER. The same file records the measured cost: ~250-300s at fleet load
# (queue-dispatch.py main(); lane-status.py:1610,1626). A bound BELOW the real cost turns a
# slow-but-successful read into a chronic abort, which is fail-closed but useless. So the
# DEFAULT is a self-bound above the measured cost, and a caller that wants the abort to fire
# INSIDE its own slice must hand that slice over -- QUEUE_DISPATCH_DEADLINE_EPOCH (absolute
# epoch seconds), which CAPS this value down. heartbeat-loop.sh does not set it yet; that is
# reported as a required out-of-repo change, not made here.
SCAN_TIMEOUT_DEFAULT = 600.0

# class -> (queue file, human label)  the queue to pull from for that class
#
# NOTE ON ORDERING WHILE MAIN IS RED: a red main blocks EVERY landing (it is the rail's base-red
# precondition), so a landing lane is useless until main is green. Rebases and reviews are NOT
# blocked by it -- they prepare PRs to land the moment main clears. So when main is red, prefer
# the 2-RAIL / 4-REVIEW / conflict classes over `land`.
CLASS_QUEUE = {
    "land":     ("LANDABLE.tsv", "land the next candidate via the rail (a red main does NOT block the rail)"),
    "ci":       ("CI-PRS.tsv",   "a CI-improvement PR: rebase if needed, fresh review at the new head, then land"),
    "conflict": ("CONFLICTS.tsv", "rebase onto origin/main, resolving ONLY mechanical conflicts"),
    "1-RETRY":  ("REMEDY.tsv",   "main is GREEN now -> just re-run the rail"),
    "2-RAIL":   ("REMEDY.tsv",   "rail moved the head and refused (see #4764)"),
    "3-BLINDSPOT": ("REMEDY.tsv", "no parseable failure identity (#6798)"),
    # ⛔ REFRESH THE BASE FIRST. THE FLEET'S MOST COMMON FALSE SIGNAL IS A RED READ FROM A BRANCH
    # THAT IS BEHIND MAIN. Measured THREE TIMES on 2026-10-04: (1) I read `blocked=10` and it was
    # base-drift staleness -- it fell to 1 in 25 min with nothing fixed; (2) lane 2a on #7127/#6788
    # found the BLOCKED was commits-behind-base; (3) 2a again on #6273 found a clause red that was
    # main's own later code, not a defect in the branch. Its own words: "A red read from a branch
    # that is behind main is a hypothesis about the branch, not a finding, until the base is
    # refreshed." Every one of those burned a review cycle on a defect that did not exist. So the
    # instruction is now explicit in the label, because the label is what the lane is handed and
    # nothing else in the pipeline tells it.
    "4-REVIEW": ("REMEDY.tsv",   "FIRST refresh the base onto origin/main (a red read from a branch that is behind main is a hypothesis about the branch, not a finding) -- THEN review at the CURRENT head, then record"),
    "5-FIX":    ("REMEDY.tsv",   "FIRST refresh the base onto origin/main (a stale branch manufactures failures that are main's own later fixes) -- THEN a genuine failure -> fix code or test"),
    # ⛔ ADDED 2026-10-04. These two ARE lane work, and their absence made every row in
    # them invisible: `CLASS_QUEUE.get(cls, ("?", "?"))[0]` resolved to a queue file named
    # "?", so `claim_next` found nothing and no lane was ever offered the row. Measured:
    # 9 rows sat in 7-DRAFT-PROMOTE/8-CLOSE with no possible route.
    "7-DRAFT-PROMOTE": ("REMEDY.tsv", "the PR is a DRAFT carrying real, unlanded work -> mark it ready, refresh the base onto origin/main, then review at the CURRENT head"),
    "8-CLOSE":  ("REMEDY.tsv",   "the work is already on main or its issue is closed -> CLOSE the PR with a one-line reason"),
    # ⛔ A DECISION NO LANE MAY MAKE IS STILL ASSIGNABLE WORK -- THE WORK IS TO ASK.
    # The defect this closes: `6-SEMANTIC` rows were in NO class, so the dispatcher skipped them, so
    # no lane was ever handed one, so the question was never written. The row then waits forever --
    # not because it cannot be routed, but because ASKING WAS UNASSIGNED. The route itself has always
    # existed and is the ordinary one: a lane posts the question as a comment, `ask-owner.py <repo>
    # <number>` gates it, it takes `owner-decision`, the owner answers, the answer routes back.
    # So the lane is given the row with an instruction NOT to resolve it, but to formulate it.
    # Measured 2026-10-04: 7 rows sat here, 2 with questions already asked (#6234, #5476), and 5 with
    # nobody assigned to ask.
    # ⛔ A COLLISION BETWEEN TWO IMPLEMENTATIONS IS NOT AN OWNER DECISION -- IT IS LANE WORK.
    # OWNER RULING, 2026-10-04T06:17:23Z on #6234, verbatim: *"this is not an owner decision, it's
    # something you can research and decide as the protocol commands."* That answer was DELIVERED
    # (#6234 carries `owner-answered` + `answer-delivered`) and NOTHING ACTED ON IT -- so 7 rows sat
    # `BLOCKED`, a verdict that means "a human must decide", on a question the human had explicitly
    # handed back. The relay worked; the consumption of its answer did not.
    # This is the single biggest unblock measured tonight: 7 SEMANTIC rows + the conflicts queue's
    # 15 terminal rows were held by the same false premise.
    # BUT THE CONTRAINDICATION TEST STILL APPLIES, and the remedy below must not erase it: research
    # and decide, UNLESS the research turns up a RECORDED DECISION the resolution would contradict --
    # then it goes to the owner (that is the one true owner case, e.g. #5196, which contradicts a
    # standing ruling on deletion semantics). Deciding is the default; only a recorded decision the
    # lane would OVERRIDE may route back.
    "6-SEMANTIC": ("REMEDY.tsv", "a collision between two competing implementations -> RESEARCH IT AND DECIDE IT YOURSELF (owner ruling 2026-10-04 on #6234: this is NOT an owner decision). Read both implementations at their live heads, take the trial-merge measurement if there is one, pick the version that satisfies both intents or preserves the most behaviour, and record WHY in the PR. Route to the owner ONLY if your research finds a RECORDED DECISION (an owner ruling, a plan-doc decision section, a Tortoise point) that your resolution would contradict -- name it concretely and use ask-owner.py; that is the contradiction test, and it is the only owner-bound case here."),
}

# ⛔ A CLASS HERE IS NOT WAITING ON A MISSING MECHANISM -- IT IS WAITING ON A QUESTION.
# The route exists and is the SAME one every other owner question uses: a lane posts the question as a
# comment, `ask-owner.py <repo> <number>` gates it, it takes the `owner-decision` label, the owner
# answers, and the answer is routed back to the lane. That is the relay, and it is not special to
# these rows.
# WHAT GOES HERE: only a class where NO lane may decide the thing, AND no lane can even be given the
# row usefully. `6-SEMANTIC` does NOT belong here -- asking is assignable work, so it now has a lane
# in CLASS_QUEUE above. Nothing currently sits in this set; keep it, because the failure it names is
# real: a class in neither dict is SKIPPED by the dispatcher and silently waits forever.
NEEDS_A_QUESTION = set()

# ⛔ 9-WIP-DRAFT WAS RETIRED 2026-10-04 -- DO NOT REINTRODUCE IT. It held 11 `wip(recovered)`
# preservation rows and had NO ROUTE TO ANYONE, so nothing ever looked at them. Lane 2a triaged
# all 11 with the exact test (`git merge-tree --write-tree` tree-oid vs main's tree, then a
# substance grep for each residue's distinctive test names): 8 CLOSE, 3 SALVAGE, 0 NEEDS-OWNER.
# **Its premise was false.** "Preservation, so no verdict is needed" does not hold -- 3 of its 11
# rows were unlanded work whose issues are still OPEN, needing exactly the routing the class
# denied them. Worse, 4 of the 11 (#5456, #5457, #5460, #5467) were missing from REMEDY.tsv
# entirely, so they had never been offered to a lane at all.
# The pattern that made the verdicts safe to make: every residue was recovered on 2026-09-26, and
# every CLOSED issue among them had been closed 1-16 days BEFORE that -- so the residue is
# post-close leftover (polish, extra tests, a local .mcp.json edit), not the fix, which landed
# elsewhere (#5457's guard is on main; #5466's whole feature is on main).
# If a preservation-only state is ever wanted, it must be a NAVIGABLE MARK -- a label on an
# ordinary PR, or an ordinary class with a lane -- never a queue class with no route.


def sh(cmd, timeout=90):
    """Run <cmd>, keeping STDOUT and STDERR apart. Returns `(rc, out, err)`.

    ⛔ THEY MUST NOT BE MERGED (#1876). `lane-status.py` writes a `DEGRADED` notice to STDERR by
    design, precisely so its stdout stays a parseable fleet read. Concatenating stderr into stdout
    landed that notice inside the roster JSON, `json.loads` raised `Extra data`, and the pass
    ABORTED (~48% of passes measured) -- a READ refused because an unrelated line was glued to it.
    A caller that genuinely wants a merged read (the cmux send path) merges at THAT call site,
    explicitly -- never by default. `rc is None` means the call timed out.
    """
    try:
        # errors="replace" is REQUIRED, not cosmetic: the cmux send path returns bytes that are
        # not valid UTF-8 (measured 0x80 at position 104, 2026-10-08), and a strict decode raised
        # UnicodeDecodeError out of this function and killed queue-dispatch.py mid-dispatch.
        # It only changes how an INVALID byte is rendered; a good result is untouched.
        p = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=timeout)
        return p.returncode, (p.stdout or ""), (p.stderr or "")
    except subprocess.TimeoutExpired:
        return None, "", "(timeout)"


def protected(lane: str) -> bool:
    return any(p in lane for p in PROTECTED)


# ── POSITIVE EVIDENCE OF NO WORK IN FLIGHT ────────────────────────────────────────
# `verdict == DONE-IDLE` ALONE IS NOT SUFFICIENT, and acting on it alone is precisely what
# SIDETRACKED a lane that was working on its own WIP (incident 2026-10-01): a lane read
# DONE-IDLE and was WORKING seconds later, so the verdict was STALE when acted on. It also
# sent to a lane that had asked a question and was WAITING on a human, and queued the
# message behind the answer.
#
# DONE-IDLE is a SAMPLE, not a state. The classifier's row already carries its own POSITIVE
# signals, so refuse unless they ALL agree that nothing is in flight:
#   * no session growth during the sample window   (`grew`)
#   * no `Working` spinner                          (`spinner`)
#   * no pending / declared / pane child            (`child`, `declared`)
#   * quiet for at least MIN_IDLE_S                 (`stale_s`)
# This is the CHEAP pre-filter. The AUTHORITATIVE check is the bracketed, lane-local probe
# in lane-guard.py, which safe-send.sh runs at the moment of sending — a guard read seconds
# earlier is the very staleness this predicate stops trusting.
MIN_IDLE_S = 120


def _in_flight(v) -> bool:
    """Is this child/declared record WORK IN FLIGHT, or a stale artifact?

    ⛔ AN ABANDONED RECORD IS NOT WORK IN FLIGHT. `lane-status.py` deliberately KEEPS an old
    child record and reports `abandoned=True` (`:78`, `:1085`, `:1114`
    `abandoned = age is not None and age > ABANDON_S`) precisely so a consumer can tell
    "work happening off-root" from "a call that died days ago". This dispatcher read the
    record and ignored the flag, so ANY lane that had ever spawned a sub-agent was withheld
    forever -- and most lanes have.

    MEASURED 2026-10-13 (the bug this fixes): `lanes read : 0 / dispatched 0` on every pass
    while the fleet was idle. The classifier returned 16 rows and 4 were DONE-IDLE, and ALL
    FOUR carried `child.abandoned=True` with ages of 186721s / 386829s / 387496s / 389592s
    (2.2-4.5 DAYS). Every one was withheld as "work happening off-root", so the dispatcher
    could never hand out a queue item -- a stale flag recording a past state, never
    revalidated. That is why the queue drained by hand instead of by the loop.

    A live child (no `abandoned` flag, or `abandoned` false) still withholds, unchanged.
    """
    if not v:
        return False
    if isinstance(v, dict):
        return not v.get("abandoned")
    if isinstance(v, (list, tuple)):
        return any(_in_flight(x) for x in v)
    # An unrecognised shape is treated as in-flight: unknown must never read as clearance.
    return True


def no_wip(row: dict) -> tuple[bool, str]:
    """Positive evidence that nothing is in flight, from the classifier's own signals."""
    if row.get("verdict") != "DONE-IDLE":
        return False, f"verdict={row.get('verdict')}"
    if row.get("grew"):
        return False, "session GREW during the sample window (a turn is in flight)"
    if row.get("spinner"):
        return False, "pane shows `Working`"
    if _in_flight(row.get("child")) or _in_flight(row.get("declared")):
        return False, "has a pending/declared child (work happening off-root)"
    stale = row.get("stale_s")
    if stale is None:
        # ⛔ `None` HERE MEANS "THERE IS NO EVENT TO MEASURE FROM", NOT "RECENTLY ACTIVE".
        # The old predicate read `stale is None` as a recency claim and withheld, printing
        # "too recently active to call idle" -- the exact opposite of what the data supports: a
        # session with NO events cannot have been active at all. MEASURED 2026-10-04: this
        # withheld 7 lanes (`pi - land-lane-4`, `land-6260`, `tortoise-sweep`, `PR 3`,
        # `pi - agent-infra`, `pi - lane-b-ci-substrate`, `8 Hosted reliability`) and the run
        # reported `dispatchable: 2 / dispatched 0` while 6 landing rows and 12 conflicts waited.
        #
        # `None` is genuinely ambiguous, so the two cases must be separated on the classifier's
        # OWN evidence rather than on the absence of a number. A lane whose session resolved and
        # holds no events reports `last: "-"` and an empty `recent`: it is a fresh, never-tasked
        # lane and is idle BY CONSTRUCTION. A lane with events but an unreadable timestamp keeps
        # the old, safe refusal -- an unknown quiet is not a clearance (same rule as `?(unread)`).
        if str(row.get("last") or "-").strip() in ("", "-") and not row.get("recent"):
            return True, ""
        return False, "quiet is UNREADABLE (not a recency claim) -- withholding, do not treat as idle"
    if stale < MIN_IDLE_S:
        return False, f"quiet only {stale}s (< {MIN_IDLE_S}s) — too recently active to call idle"
    return True, ""


def norm(lane: str) -> str:
    """Normalise a lane label for matching.

    lane-status.py reports some lanes as "land-lane-1 (6AC480DF)" -- the id is appended
    when the workspace's custom_title is absent and the pane is identified by its
    directory. That suffix is a NAMING ARTIFACT, not a different lane, so matching on the
    raw string silently drops every such lane (measured: 4 of the 9 assigned lanes).
    Strip a trailing parenthesised token and any 'phi - ' prefix before comparing.
    """
    s = lane.strip()
    if s.endswith(")") and " (" in s:
        s = s[: s.rfind(" (")].strip()
    for pre in ("\u03c0 - ", "\u03c0-"):
        if s.startswith(pre):
            s = s[len(pre):].strip()
    return s


class LaneReadError(RuntimeError):
    """The lane roster could NOT be read. NOT the same value as 'the fleet is empty'.

    This type exists so the two can never be confused by a caller: `lanes()` cannot RETURN
    an empty list on a failed read, because it raises instead. See `_abort_unreadable`.
    """


def lanes(scan_timeout=None):
    """Per-lane verdicts from the existing multi-signal classifier (do not reinvent).

    ONE SCAN PER PASS. This function is called exactly once, fleet-wide, and never with
    `--only` (see `main()` for why the second, subset read was removed). Issuing only the
    fleet-wide read matters for a reason beyond this file's own cost: `lane-status.py`'s
    snapshot cache is a SINGLE FILE `~/.pi/agent/state/lane-status.cache` keyed on `--only`
    (read and written by `lane-status.py`'s own cache helpers -- NAMED, not numbered: the line
    numbers that used to be here had already rotted), so a `--only` call from here
    OVERWRITES the fleet-wide snapshot under the `[null]` key. The next fleet-wide consumer
    then MISSES and re-runs a full ~250-300s scan -- which is exactly what `lane-actions.py`
    does in its invoke path (its `--json` read of the fleet snapshot), and therefore what
    `pr-doctor` pays (its `lane-actions.py --json` call). ⛔ NAMED, NOT NUMBERED (`#1872` review
    rounds 10-11): `pr-doctor.py`'s number was already stale when it was read; `lane-actions.py`'s
    range was CORRECT on `origin/main` and moved by the +3 net lines this branch added. The reason to
    name the sites anyway is that the next edit either side rots a number again -- not that every
    number replaced here was wrong. By never issuing `--only`, this tool can no longer evict that
    snapshot. (⛔ NOT `lane-status.last.json`: that file is the heartbeat's `tee` copy
    (`orchestrator-heartbeat.sh:291-292`) and no `--only` call touches it. An earlier
    revision of this docstring named it; that was wrong, corrected here.)

    PARTIAL READS ARE REFUSED TOO. `lane-status.py` marks every row `degraded` when the cmux
    registry read failed (the `degraded=(LIVE_READABLE is False)` construct in `lane-status.py` --
    named, not numbered, per the NAMED-NOT-NUMBERED rule stated above), and such a roster is the
    hand-written TSV alone -- every live-only lane INVISIBLE. It is non-empty
    and rc=0, so it would otherwise read as a complete, healthy fleet; `lane-actions.py`
    already refuses exactly this payload (`_refuse_if_degraded`), and so do we.

    FAIL-CLOSED. A failed, timed-out, truncated or EMPTY read raises `LaneReadError`; it is
    NEVER returned as an empty list. MEASURED 2026-10-13 (the P0 this fixes): `sh()` returns
    `(None, "(timeout)")` on `TimeoutExpired`, the old code turned that into `return []`, and
    the pass then printed `lanes READ : 0 / dispatchable: 0 / dispatched 0` and EXITED 0 --
    byte-identical to a healthy empty fleet, while 17 lanes sat idle. `main()` aborts with
    exit 3 (the same polarity `lane-status.py:1670` already uses for an empty roster).
    """
    cmd = ["python3", LANE_STATUS, "--json"]
    # Never hand `subprocess.run(timeout=None)` an unbounded read by accident: `None` means
    # "wait forever" there, which is precisely the unbounded step this bound exists to remove.
    # `<= 0` and NaN/Inf are treated the same way -- a non-finite or non-positive bound is not
    # a bound, and passing it through would silently disable the guard.
    try:
        _tmo = float(scan_timeout)
    except (TypeError, ValueError):
        _tmo = float(SCAN_TIMEOUT_DEFAULT)
    if not (_tmo > 0) or _tmo == float("inf"):
        _tmo = float(SCAN_TIMEOUT_DEFAULT)
    rc, out, err = sh(cmd, timeout=_tmo)
    if rc is None:
        raise LaneReadError(
            f"lane-status.py TIMED OUT after {_tmo}s (rc=None) -- the scan was killed, "
            f"so the roster is UNKNOWN, not empty")
    if rc != 0:
        raise LaneReadError(
            f"lane-status.py exited rc={rc}: "
            f"{(out or '').strip()[:200] or (err or '').strip()[:200] or '(no output)'}")
    # ⛔ THE JSON PARSE IS OVER STDOUT ONLY. A DEGRADED notice lives on stderr (that is the whole
    # point of #1876): it is surface for the operator, never part of the roster. An UNREADABLE
    # roster still aborts below -- fail-closed is intact; only the corrupted-read path is fixed.
    if not out.strip().startswith("["):
        raise LaneReadError(
            f"lane-status.py produced non-JSON output (rc={rc}): "
            f"{(out or '').strip()[:200] or (err or '').strip()[:200]}")
    try:
        rows = json.loads(out)
    except Exception as exc:                                     # noqa: BLE001
        raise LaneReadError(f"lane-status.py output unparseable: {exc}") from exc
    if not isinstance(rows, list):
        raise LaneReadError(f"lane-status.py returned {type(rows).__name__}, not a list")
    if not rows:
        # An empty roster is a REFUSAL, not a verdict -- the same rule lane-status.py enforces
        # on its own side (`lane-status.py:1660-1670` raises SystemExit(3) rather than publish
        # it). If it reaches us anyway (an older lane-status, a stale cache from before that
        # guard), refuse here too: an empty fleet is not a read, and THIS is the exact value
        # that was silently spent as "no lanes to dispatch" in the incident.
        raise LaneReadError(
            "lane-status.py returned an EMPTY roster -- an empty fleet is not a read "
            "(refusing, exactly as lane-status.py:1670 does)")
    _degraded = [r.get("lane") for r in rows
                 if isinstance(r, dict) and r.get("degraded")]
    if _degraded:
        # A DEGRADED (TSV-ONLY) ROSTER IS A PARTIAL READ, NOT A COMPLETE FLEET. Every live-only
        # lane is absent from it, so it UNDER-REPORTS the fleet (it read rc=0 and is non-empty,
        # so nothing else here would catch it). Named lanes, so the abort says who is missing.
        raise LaneReadError(
            f"lane-status.py returned a DEGRADED roster ({len(_degraded)} row(s) could not see "
            f"the cmux registry -- live-only lanes are INVISIBLE): "
            f"{', '.join(str(x) for x in _degraded[:8])}"
            + (" ..." if len(_degraded) > 8 else ""))
    return rows


def _abort_unreadable(exc: Exception) -> int:
    """Refuse the pass when the lane roster could not be read. NEVER prints `lanes READ : 0`.

    Exit 3 is deliberate: it is the polarity `lane-status.py:1670` already uses for an
    unreadable roster, so a supervisor that distinguishes "roster unreadable" from "success"
    needs no new convention. The summary is written so that no line of it can be mistaken for
    an empty-but-fine fleet -- the mislabel that hid this defect for every earlier run.
    """
    print("=" * 78)
    print("ABORT — LANE ROSTER UNREADABLE. The pass did NOT run and sent nothing.")
    print("  · lanes READ  : UNKNOWN — the scan FAILED (this is NOT `lanes READ: 0`)")
    print("  · dispatchable: UNKNOWN — the fleet is NOT known to be empty or fed")
    print("  · dispatched  : 0 — no claim was taken and nothing was sent")
    print(f"  · reason      : {exc}")
    print("  · A failed read is never spent as an empty fleet; the armed loop retries next tick.")
    print("=" * 78)
    return 3



def assignments():
    """lane -> class, from a durable file. Absent file = nothing to dispatch."""
    out = {}
    if not os.path.exists(ASSIGNMENTS):
        return out
    for i, line in enumerate(open(ASSIGNMENTS, errors="replace")):
        if i == 0 or not line.strip() or line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) >= 2:
            out[f[0].strip()] = f[1].strip()
    return out


def cool(lane: str) -> bool:
    """Has this lane been spoken to inside the cooldown window? PURE READ.

    It deliberately does NOT write the marker. An earlier version did, and the bug it caused
    is the exact reason to keep them apart: running the DRY RUN consumed the cooldown, so the
    subsequent --apply skipped every lane as "inside the 900s cooldown" -- a dry run that
    silently disarms the thing it just described. Inspecting a system must not change it.
    """
    p = os.path.join(COOLDOWN_DIR, lane.replace("/", "_").replace(" (", "_("))
    if os.path.exists(p) and (time.time() - os.path.getmtime(p)) < COOLDOWN_S:
        return False
    return True


def mark_sent(lane: str) -> None:
    """Record that we actually dispatched to this lane, starting its cooldown."""
    os.makedirs(COOLDOWN_DIR, exist_ok=True)
    p = os.path.join(COOLDOWN_DIR, lane.replace("/", "_").replace(" (", "_("))
    if os.path.exists(p):
        os.utime(p, None)
    else:
        open(p, "w").close()


class QueueReadError(RuntimeError):
    """The work queue could NOT be read. NOT the same value as 'the queue is empty'.

    The SAME polarity as `LaneReadError`, one function down: `claim.py` exits 2 for an
    unreadable/missing queue (`claim.py:70-76`, "a missing queue is UNKNOWN, not empty"), and
    `sh()` returns `(None, "", "(timeout)")` on a kill. Collapsing those to `None` made `main()`
    print `SKIP <lane>: <queue> has nothing left` and exit 0 -- a failed read spent as an empty
    queue, which is the very defect this file was fixed for. The function's own docstring
    states the violated rule: "An empty result from a queue you did not read is not evidence
    of absence".
    """


def claim_next(lane_id: str, queue_file: str):
    """Take the next unclaimed item for this lane FROM THE QUEUE ITS CLASS NAMES.

    MEASURED DEFECT this argument closes: `claim.py` reads LANDABLE.tsv and nothing else.
    Called without --queue it answers NONE for a REMEDY lane -- correctly, because it never
    read REMEDY.tsv -- and a dispatcher that trusted that answer would report "nothing left"
    forever while 46 work orders sat unread. An empty result from a queue you did not read is
    not evidence of absence (the same rule that caught the unguarded find earlier).

    RETURNS: (item, path) with `item` a real row, or (None, path) ONLY when the queue was
    READ and genuinely answered NONE. A read that failed raises `QueueReadError`.
    """
    path = os.path.join(STATE, queue_file)
    rc, out, err = sh(["python3", CLAIM, "next", lane_id, "--queue", path], timeout=60)
    if rc is None:
        raise QueueReadError(f"claim.py TIMED OUT reading {queue_file} (rc=None) -- UNKNOWN, not empty")
    if rc != 0:
        raise QueueReadError(
            f"claim.py exited rc={rc} reading {queue_file}: "
            f"{(out or '').strip()[:160] or (err or '').strip()[:160] or '(no output)'}")
    if not out.strip():
        raise QueueReadError(f"claim.py produced no output reading {queue_file} (rc=0) -- UNKNOWN, not empty")
    first = out.strip().splitlines()[0].strip()
    if not first or first.upper().startswith("NONE"):
        return None, path          # READ, and genuinely empty
    return first, path


_QV_MODULE = None


def _queue_verdicts():
    """Load the sticky-verdict resolver (#1563) from THIS script's own directory.

    Path-loaded for the same reason `_turn_classify()` is: the farm copies this file FLAT
    into `$DEST/scripts/`, and `queue_verdicts.py` is farmed BESIDE it (`pi-bootstrap/
    setup.sh`'s `fleet_srcs`), so a sibling path is the true one both in the repo and on a
    fresh box. `sys.modules` is populated BEFORE `exec_module` because the module defines
    dataclasses under `from __future__ import annotations`; without the registration the
    dataclass machinery looks the owning module up by name and gets None.
    """
    global _QV_MODULE
    if _QV_MODULE is None:
        import importlib.util
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "queue_verdicts.py")
        spec = importlib.util.spec_from_file_location("queue_verdicts", p)
        if spec is None or spec.loader is None:
            raise QueueReadError(f"queue_verdicts.py is not loadable at {p} (#1563)")
        mod = importlib.util.module_from_spec(spec)
        sys.modules["queue_verdicts"] = mod
        spec.loader.exec_module(mod)
        _QV_MODULE = mod
    return _QV_MODULE


def _claims_text():
    """CLAIMS.tsv text. A MISSING file is a queue nobody has claimed yet (no verdicts); an
    existing-but-unreadable one is UNKNOWN and raises — the same polarity as claim.py, whose
    unreadable queue exits 2 rather than answering empty."""
    path = os.path.join(STATE, "CLAIMS.tsv")
    if not os.path.exists(path):
        return ""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError as exc:
        raise QueueReadError(f"CLAIMS.tsv unreadable ({exc}) -- UNKNOWN, not 'no verdicts'")


def pr_of(item: str):
    """The PR number in a queue item. `claim.py next` prints an item beginning `PR <n>`
    (both `free`/`done` call sites take `item.split()[1]`), so the explicit form is preferred
    and a bare number is the fallback."""
    m = re.search(r"PR\s+(\d+)", item or "") or re.search(r"(\d+)", item or "")
    return m.group(1) if m else None


def verdict_guard(queue_path: str, pr: str):
    """Is this item still SERVABLE? Replays CLAIMS.tsv with #1563's sticky-terminal rule.

    THE DEFECT THIS CLOSES, measured on #1563 (7 instances in one session): claim.py resolves
    CLAIMS.tsv last-write-wins per PR and `SKIPPED` is non-terminal on every queue, so a SKIPPED
    written by ANY lane resurrects an item another lane already terminated as FIXED/BLOCKED --
    and `next` re-serves it as fresh work. The sharpest measured case is #5630, where the ONLY
    durable record of a STANDING OWNER DIRECTIVE (`do not start #5630`) was a BLOCKED row, and a
    later SKIPPED handed the item to a lane as new work.

    This is the seam where it stops: the item has already been claimed, so the caller REFUSES to
    deliver it and re-affirms the terminal verdict (`Guard.reaffirm`) with the later observation
    recorded as an annotation. Re-affirming is load-bearing, not cosmetic: releasing the claim
    without it would leave claim.py serving the same item to this lane forever (`FREE` restores
    it to the pool), which is the starvation the same issue measures.
    """
    qv = _queue_verdicts()
    return qv.guard(qv.resolve(_claims_text(), queue_path), pr)


def no_pr_note(lane: str, item: str) -> str:
    """The LOUD line for the ONE input the sticky-verdict gate cannot check at all (#1563).

    `verdict_guard` is keyed on the PR number (`pr_of`), so a served item with no digit run —
    a `claim.py next` format drift, or a queue row that is not PR-keyed — cannot be checked.
    That is deliberately FAIL-OPEN: stalling delivery instead would burn a whole lane on a
    format drift, and the lane would then be silent for every item behind it. But it must be
    VISIBLE, for the same reason its two neighbours in the same block are: `READ-FAILED`
    withholds the lane and says it is NOT read as empty, and `VERDICT-GUARD UNAVAILABLE` says
    a resurrected terminal item can be served. A gate that goes QUIET on an input it did not
    expect is how a no-op gate reads green — and "the check did not run" is then
    indistinguishable, in the log, from "the check ran and passed".
    """
    head = (item.splitlines() or [""])[0][:60]
    return (f"  ⚠ VERDICT-GUARD SKIPPED {lane}: no PR number in the served item "
            f"({head!r}) — sticky-verdict check did NOT run (#1563)")


def refuse_resurrected(lane: str, pr: str, g, apply_now: bool):
    """Do NOT deliver a resurrected item: release the claim, and re-affirm the terminal verdict.

    Re-affirming is load-bearing, not cosmetic. `FREE` RESTORES the item to the pool (#1563's own
    measurement: `free` and the immediate re-serve carried the same timestamp), so releasing the
    claim alone would leave claim.py serving this same item to this lane forever. Writing the
    terminal verdict back — with the later observation kept in the reason — makes claim.py's own
    last-write-wins resolution terminate the row again, so the item stops being offered to
    EVERY lane, and nothing is lost: the observation is in the row, and `queue_verdicts.py`
    reports it as an annotation.

    A DRY RUN WRITES NOTHING and still releases the claim (claim_next already took it; inspecting
    the system must not consume an item — the same rule as `cool()`).

    RETURNS the verdict written, or None in a dry run.
    """
    sh(["python3", CLAIM, "free", lane, pr], timeout=60)
    if not apply_now:
        return None
    subprocess.run([sys.executable, CLAIM, "done", lane, pr, g.reaffirm, g.reaffirm_reason],
                   capture_output=True, text=True, errors="replace")
    return g.reaffirm


def outcome_menu(lane: str, pr, queue_path: str) -> str:
    """The verdict menu a lane is told to record, for THE QUEUE THIS ROW CAME FROM.

    #1563's SECOND route into the same root, measured: the menu was one unconditional string
    (`LANDED|REFUSED|SKIPPED`) while claim.py's terminal set is class-dependent, so a `conflict`
    row's menu contained NO verdict that terminates the row -- `REFUSED` is a work order there.
    A lane obeying its instructions therefore could not dispose of its own row and the loop
    needed no second lane at all (#5461 looped 6 lanes / 23 rows). The menu is now derived from
    the queue, and the lane label is QUOTED: it routinely contains spaces and parentheses
    (`4a Retrieval and traversal`, `land-lane-2 (73A9A92C)`), and an unquoted label splits the
    `done` invocation across columns (tortoise#6915).
    """
    qv = _queue_verdicts()
    words = "|".join(qv.verdict_menu(queue_path))
    return (f'Record the outcome with: python3 {CLAIM} done "{lane}" {pr if pr else "<pr>"} '
            f'<{words}> "<reason>" so the queue stays honest, then take the next one. '
            f'If it prints NONE, stop. A TERMINAL verdict is STICKY: a later SKIPPED is '
            f'recorded as an annotation and does not re-open the item; to re-open it '
            f'deliberately, record {qv.reopen_hint()}.')


_TC_MODULE = None


def _turn_classify():
    """turn-classify.py has a HYPHEN, so `import turn_classify` fails. Load it by
    path once and cache: one implementation of turn classification everywhere."""
    global _TC_MODULE
    if _TC_MODULE is None:
        import importlib.util
        _p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "turn-classify.py")
        _spec = importlib.util.spec_from_file_location("turn_classify", _p)
        _mod = importlib.util.module_from_spec(_spec)
        _spec.loader.exec_module(_mod)
        _TC_MODULE = _mod
    return _TC_MODULE


def classify_last_turn(row):
    """THE LAST-TURN GATE (Jev, reused from turn-classify.py — one implementation).

    DONE-IDLE says the lane is not writing. It does NOT say WHY it stopped, and the
    two cases need OPPOSITE responses:

        finished_the_work       -> hand it the next queue item (what this tool does)
        stopped_with_work_left  -> send a CONTINUE, not a new item (it has WIP; a new
                                   item is the sidetrack that started all this)
        asked_the_owner         -> leave it alone; the answer queue owns it
        unreadable              -> WITHHOLD (never act on an unestablished read)

    MEASURED 2026-10-01: 4 lanes read DONE-IDLE by the classifier, were handed items,
    and their panes showed direct responses to THAT dispatch — i.e. the verdict alone
    cannot distinguish 'between steps' from 'done'. The last turn's own words can.
    Jev is the standing division of labour for exactly this: prose judgement goes to
    the model, mechanical fields stay in code (turn-classify.py header).
    """
    tc = _turn_classify()
    sid = row.get("sid")
    path = tc.session_file_for(sid) if sid else None
    if not path or not os.path.exists(path):
        # ⛔ THE ABSENCE OF A TRANSCRIPT IS NOT AN UNREADABLE TURN.
        # `unreadable -> WITHHOLD` exists so the tool never acts on a turn it could not read.
        # There is no turn here to misread: the lane has never been given work, so nothing can be
        # in flight and `finished_the_work` is true BY CONSTRUCTION rather than by inference.
        # MEASURED 2026-10-04: this withheld 6 freshly-relaunched lanes (`pi - land-lane-4`,
        # `land-6260`, `tortoise-sweep`, `PR 3`, `pi - agent-infra`, `pi - lane-b-ci-substrate`),
        # every one of them a live pi sitting at an idle prompt (`0.0%` footer, no spinner), while
        # 6 claimable landing rows and 12 conflicts waited. `dispatched 0` was the result.
        # NARROWNESS MATTERS: a transcript that EXISTS but cannot be parsed still returns None
        # below -- that is the case the doctrine is for, and it is untouched.
        return "finished_the_work", {"no_transcript": True}
    turn = tc.last_turn_text(path)
    if not turn.strip():
        return None, "no assistant text in the last turn"
    # A TRANSIENT Jev failure must not stall the queue for a tick. MEASURED 2026-10-01:
    # jev_choice returned None on a timed-out and an SSL-EOF call (both transient; the
    # same call succeeded 3/3 seconds later), and each one WITHHELD a lane. Retry a
    # couple of times; a persistent failure still WITHHOLDS, which is correct -- an
    # unreadable classification is not a licence to dispatch.
    last = {}
    for attempt in range(3):
        choice, meta = tc.jev_choice(turn)
        if choice:
            return choice, meta
        last = meta or {}
        time.sleep(2 + attempt * 3)
    return None, {"jevic_failed_after": 3, **last}


def send_continue(lane, ws, dry=True):
    """The CONTINUE for a false-idle lane: it stopped with work left. The text is
    turn-classify.py's own NO_PAUSE_NUDGE — the fleet already knows this message —
    so there is ONE continue-message, from every door."""
    tc = _turn_classify()
    msg = tc.build_message("no_pause", lane)
    os.makedirs(TMPD, exist_ok=True)
    brief = os.path.join(TMPD, f"qd-continue-{lane.replace(' ', '_')}.txt")
    with open(brief, "w") as f:
        f.write(msg)
    if dry:
        print(f"  WOULD CONTINUE {lane} (stopped_with_work_left — keep going, no new item)")
        return "dry"
    # TIMEOUT RAISED 240 -> 900 (2026-10-02). MEASURED: the send path is not failing on
    # EVIDENCE, it is failing on BUDGET. safe-send.sh runs lane-guard.py, which brackets the
    # pane with SEVERAL cmux reads (40s for one lane when cmux is healthy, and cmux has been
    # flapping at 1-16s per call). At 240s the caller cut the guard off mid-decision and got
    # `rc=None (timeout)` -- an answer of NOTHING, from which "busy" and "unreadable" and
    # "slow" cannot be told apart, so a genuinely idle lane was simply not fed. Two lanes
    # (5&9 MCP and SDK surface, 8 Hosted reliability) were lost to this in one pass while
    # the fleet sat at 18 idle. Raising the budget does NOT relax the guard: it lets the
    # existing gate ANSWER instead of timing out, so a real refusal still refuses.
    #
    # ⛔ AND THIS LINE'S INDENTATION IS LOAD-BEARING (broken once, 2026-10-02): the first
    # version of this edit left `rc, out = ...` at 8 spaces, which put it INSIDE `if dry:`
    # immediately after that branch's `return`. Comments do not create blocks, so the line
    # silently belonged to the dry branch and was unreachable; every `--apply` pass then died
    # with `UnboundLocalError: rc` -- the dispatcher crashed on EVERY cycle for 20 minutes and
    # fed nobody while the fleet sat idle. A no-op in a dry run must not be a crash in apply.
    # ⛔ EXPLICIT merge at the CALL SITE: this path's consumer prints one string, and safe-send.sh
    # legitimately reports on stderr. The default is now split (#1876); a caller that wants the
    # merge asks for it here rather than making every JSON reader inherit it.
    rc, out, err = sh(["bash", SAFE_SEND, ws, lane, brief], timeout=900)
    out = (out or "") + (err or "")
    if rc == 0:
        print(f"  CONTINUED {lane} (stopped_with_work_left — resume your own WIP)")
        mark_sent(lane)
    elif rc == 3:
        print(f"  BUSY {lane} — continue refused; the lane is working after all. Correct outcome.")
    else:
        print(f"  CONTINUE-FAILED {lane} rc={rc} {out.strip()[:60]}")
    return rc


def _single_instance():
    """Take a NON-BLOCKING exclusive lock, or refuse to run.

    WHY (measured 2026-10-01): this dispatcher is armed inside heartbeat-loop.sh, and its
    per-lane cost is now minutes (each send consults lane-guard.py, which brackets the pane
    with several cmux reads). An operator running it by hand -- or simply a slow pass --
    therefore overlaps the loop's pass, and NOTHING anywhere stopped two passes from
    feeding the same lane. The 900s cooldown only covers a lane that ALREADY sent: two
    passes that both check it inside the same window both pass their own check. MEASURED:
    two `queue-dispatch.py --apply` processes ran concurrently (mine and the loop's), which
    would have handed one lane two different queue items.

    The claim lock in claim.py protects one ITEM from two lanes; this protects one LANE
    from two dispatchers. They are different invariants and both are needed.
    """
    import fcntl
    path = os.path.join(STATE, "queue-dispatch.lock")
    fh = open(path, "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("  another queue-dispatch is already running — exiting rather than racing it")
        return None
    return fh  # keep the handle open for the process lifetime


def _env_scan_timeout() -> float:
    """The default scan bound from the environment, parsed DEFENSIVELY.

    A non-numeric `QUEUE_DISPATCH_SCAN_TIMEOUT` must not turn `--help` (or any run) into a
    traceback at argparse time -- a bad tuning knob is a warning and a fallback, never a crash.
    """
    raw = os.environ.get("QUEUE_DISPATCH_SCAN_TIMEOUT")
    if raw is None:
        return float(SCAN_TIMEOUT_DEFAULT)
    try:
        v = float(raw)
    except ValueError:
        print(f"  ⚠ QUEUE_DISPATCH_SCAN_TIMEOUT={raw!r} is not a number — using "
              f"{SCAN_TIMEOUT_DEFAULT}s")
        return float(SCAN_TIMEOUT_DEFAULT)
    if not (v > 0) or v == float("inf"):
        print(f"  ⚠ QUEUE_DISPATCH_SCAN_TIMEOUT={raw!r} is not a usable bound — using "
              f"{SCAN_TIMEOUT_DEFAULT}s")
        return float(SCAN_TIMEOUT_DEFAULT)
    return v


def pr_first_gate(state_dir=None, now_s=None):
    """The owner's dispatch priority: NEW ISSUE WORK IS SKIPPED WHILE UN-OWNED PRs EXIST.

    ⛔ WHY THIS EXISTS, AND WHY HERE (owner, 2026-10-18): "un-owned PRs first — a PR is owned only
    if a LIVE process has it — and only then pick issues for new work." This tool is the fleet's
    ISSUE dispatcher, so this is the only place the second half of that rule can be enforced.
    `scripts/pr-doctor.py` measures it (a cwd/process probe, never a claim) and publishes
    `issue_work` in `$STATE/pr-doctor.status.json`; before this gate, `pr-doctor` printed the
    decision into its own log and NOTHING read it — a decision nobody took.

    Returns "" (new issue work may proceed) or the reason to skip, ready to print.

    ⛔ EVERY UNCERTAIN CASE PROCEEDS, AND SAYS SO. A missing, stale, unreadable or failed record
    means the priority was NOT measured — and blocking all issue dispatch on a dead measurement is
    how one broken component starves the rest of the fleet (`$STATE/PR-DOCTOR-OFF`, a broken
    sidecar, a pr-doctor that cannot read GitHub). The gate behaves exactly like every other
    recorder in this file: it refuses only on a POSITIVE reading, and names the evidence.
    """
    p = os.path.join(state_dir or PR_DOCTOR_STATE, "pr-doctor.status.json")
    try:
        with open(p) as fh:
            d = json.load(fh)
        at = float(d.get("at_epoch") or 0)
        rc = int(d.get("rc"))
        work = str(d.get("issue_work") or "")
        reason = str(d.get("reason") or "")[:110]
    except FileNotFoundError:
        print("  (priority gate not applied: pr-doctor has recorded no pass yet)")
        return ""
    except Exception as e:
        print(f"  (priority gate not applied: the pr-doctor record is unreadable: {type(e).__name__})")
        return ""
    age = max(0, int((now_s if now_s is not None else time.time()) - at))
    if age > PR_FIRST_MAX_AGE_S:
        print(f"  (priority gate not applied: the pr-doctor record is STALE, {age // 60}m old)")
        return ""
    # ⛔ `rc != 0` IS NOT "NOTHING WAS MEASURED" (2026-10-18, review). The pass publishes `issue_work`
    # on rc=2 (it classified the PRs and refused only the DISPATCH) and on rc=3 ("I read it, I placed
    # the work, and NO LANE WOULD TAKE IT") -- so keying the gate on rc inverted the owner's rule
    # exactly when the fleet was blind on some checks or every lane refused an order, and the live
    # record on this box was `RED rc=3 … no lane accepted`, which the gate ignored. The reading is
    # the FIELD: a record without `issue_work` came from a path that never measured ownership (the
    # open-PR read failed, the queue was empty, checks were unreadable, no roster), and that is the
    # only case with nothing to act on.
    if work not in ("SKIPPED", "ELIGIBLE"):
        print(f"  (priority gate not applied: the last pr-doctor pass measured no ownership "
              f"verdict, rc={rc}: {reason})")
        return ""
    if rc != 0:
        # Measured, but the pass still refused: say it, because a SKIPPED decision taken under a
        # refusal is worth knowing about (the PR side is not healthy either).
        print(f"  (the pr-doctor pass that measured this also refused, rc={rc})")
    if work != "SKIPPED":
        return ""
    return f"issues: SKIPPED (un-owned PRs exist) — pr-doctor {age // 60}m ago: {reason}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="actually send (default: dry run)")
    ap.add_argument("--status", action="store_true", help="report only")
    # ⛔ BOUND THE PER-PASS WORK SO THE DISPATCHER ALWAYS FINISHES INSIDE ITS SLICE.
    # MEASURED 2026-10-04: with 11 dispatchable lanes the dispatcher was killed by its own
    # time bound before it dispatched anything -- `07:24:09 STALL queue-dispatch.py exceeded
    # 237s and was killed (rc=143)` -- because the cost is ~15s of JEV per lane in
    # `classify_last_turn` plus two `lane-status` reads over 29 lanes. Raising the budget cannot
    # fix this: the pass budget is pinned to the owner's 5-9 min cadence, and an unbounded step
    # inside a fixed window is the defect, not the window size. So examine at most N lanes per
    # pass and let the NEXT pass take the rest -- the loop runs every ~9 min, and a lane that is
    # idle now is idle in nine minutes. Bounded work beats a bigger allowance.
    ap.add_argument("--max-lanes", type=int, default=4,
                    help="max dispatchable lanes to EXAMINE per pass (bounds the JEV cost; "
                         "the next pass takes the rest)")
    # ⛔ BOUND THE FLEET READ'S WALL CLOCK. lane-status.py has NO internal deadline, so a scan
    # at heavy load can outlive this process's slice and be killed from outside (`sh()` returns
    # `(None, '(timeout)')`). The bound matters ONLY because hitting it now ABORTS with exit 3
    # (`LaneReadError` -> `_abort_unreadable`) instead of being spent as an empty fleet.
    # Resolution order: `--scan-timeout` (default: QUEUE_DISPATCH_SCAN_TIMEOUT, else the constant),
    # then CAPPED DOWN by QUEUE_DISPATCH_DEADLINE_EPOCH (an ABSOLUTE epoch the caller must not be
    # exceeded -- how a supervisor hands over its own remaining slice). The deadline can only
    # LOWER the bound, never raise it past an explicit flag.
    # RECOMMENDED out-of-repo change (reported, not made): heartbeat-loop.sh should export
    # QUEUE_DISPATCH_DEADLINE_EPOCH when it launches this tool, so the bound tracks its slice.
    ap.add_argument("--scan-timeout", type=float, default=_env_scan_timeout(),
                    help="hard wall-clock bound (s) for the one fleet read; hitting it ABORTS "
                         "the pass (exit 3) — it is never spent as an empty fleet")
    ap.add_argument("--cooldown", type=int, default=COOLDOWN_S)
    args = ap.parse_args()

    # A SINGLETON. Two passes must never feed the same lane (see _single_instance).
    _lock = _single_instance()
    if _lock is None:
        return 0

    globals()["COOLDOWN_S"] = args.cooldown

    # The hard bound actually handed to `sh()`: the explicit flag, further capped by the
    # caller's remaining slice if it advertised a deadline. Never <= 0 (that would be an
    # instant kill, not a bound) -- a spent slice still gets a small floor so the read can
    # answer, and if it cannot, the pass ABORTS visibly rather than reporting an empty fleet.
    _scan_timeout = args.scan_timeout
    _dl = os.environ.get("QUEUE_DISPATCH_DEADLINE_EPOCH")
    if _dl:
        try:
            _scan_timeout = min(_scan_timeout, max(30.0, float(_dl) - time.time()))
        except ValueError:
            print(f"  ⚠ QUEUE_DISPATCH_DEADLINE_EPOCH={_dl!r} is not a number — ignoring it")

    a_raw = assignments()
    a = {norm(k): v for k, v in a_raw.items()}

    # ── ONE SCAN, NOT TWO (2026-10-13) ────────────────────────────────────────────────────
    # WHAT THE SECOND READ USED TO BE, AND WHY IT IS GONE.
    # It was a genuine second `lane-status.py --json` observation of the candidate lanes,
    # introduced to catch a lane that started working between the read and the send. It is
    # removed here for two reasons, both measured:
    #
    #   1. IT WAS THE THING THAT DESTROYED THE SHARED CACHE. `lane-status.py` keeps ONE
    #      snapshot file keyed on `--only` (its own cache read/write helpers -- named, not
    #      numbered: the line numbers that used to be here had rotted),
    #      so this caller's subset read OVERWROTE the fleet-wide snapshot the tick had just
    #      paid for. Every later consumer in the pass (notably `lane-actions.py`, and through
    #      it `pr-doctor`) then MISSED and re-ran the full ~250-300s fleet scan -- and this
    #      tool paid it again itself on the next pass. The read budget the tick had already
    #      spent was thrown away once per pass, by this line. MEASURED 2026-10-13: every
    #      `pr-doctor` pass logged `LANE READ FAILED ... lane-status.py failed: TimeoutExpired`.
    #      With the subset read gone, this caller only ever issues the fleet-wide key, so it
    #      cannot evict that snapshot again.
    #   2. ITS GUARD IS ALREADY PERFORMED, AUTHORITATIVELY, AT SEND TIME. `safe-send.sh` runs
    #      `lane-guard.py`, which is a LANE-LOCAL BRACKETED probe (its own header: "A bracket,
    #      not a snapshot: the file is read again AFTER the other probes, so a turn that begins
    #      DURING the probe is caught rather than missed") and refuses exit 3, on which this
    #      file already RELEASES the claim and retries (`rc == 3` branch below). A cheap pre-read
    #      that re-scans the fleet to predict a check that is re-run anyway is pure duplication;
    #      the authoritative refusal is unchanged.
    #
    # The distinction the second read was also credited with -- "the fleet is genuinely empty"
    # vs "the scan was starved" -- is now made by FAIL-CLOSED read 1: a starved scan raises
    # `LaneReadError` and aborts (exit 3). It can never be read as an empty fleet.
    #
    # The positive no-WIP evidence that remains is `no_wip()` below (spinner / child / declared /
    # grew / stale_s), applied to this single read.
    try:
        rows = lanes(scan_timeout=_scan_timeout)
    except LaneReadError as exc:
        return _abort_unreadable(exc)
    # ⛔ KEEP THE READ COUNT BEFORE ANY FILTERING. This line printed `len(rows)` after the
    # keep-filter, so a TOTALLY BLIND reader and a HEALTHY idle fleet both printed
    # "lanes read : 0" -- and the later `dispatched 0` looked like a quiet fleet.
    # MEASURED 2026-10-13: that mislabel is what hid the abandoned-child bug for every one
    # of the loop's runs. Report the read count and the dispatchable count separately so
    # "I read nothing" and "I found nothing to do" can never again be the same output.
    _read_n = len(rows)

    print(f"queue dir   : {STATE}")
    print(f"assignments : {len(a)} lane(s)")
    for lane, cls in sorted(a.items()):
        q = CLASS_QUEUE.get(cls, ("?", "?"))[0]
        print(f"    {lane:34} -> {cls:12} ({q})")
    if not a:
        print("    (no LANE-ASSIGNMENTS.tsv -- nothing to dispatch; this is the safe state)")

    print()
    idle = [r for r in rows if r.get("verdict") == "DONE-IDLE" and not protected(r.get("lane", ""))]
    # The verdict alone is NOT the gate: keep only lanes with positive no-WIP evidence.
    dispatchable, withheld = [], []
    for r in idle:
        ok, why = no_wip(r)
        (dispatchable if ok else withheld).append((r, why))
    idle = [r for r, _ in dispatchable]
    print(f"lanes READ  : {_read_n}   (one scan — see main(): the subset re-read was removed)   "
          f"dispatchable: {len(idle)}")
    if withheld:
        print(f"              WITHHELD — DONE-IDLE but no positive no-WIP evidence ({len(withheld)}):")
        for r, why in withheld:
            print(f"    {r.get('lane','')[:34]:34} {why}")
    # Bound the per-pass work (see --max-lanes). Deferred lanes are named, never silently dropped:
    # a dispatcher that quietly ignores lanes looks identical to one that has nothing to do.
    _deferred = []
    if len(idle) > args.max_lanes:
        _deferred = [r.get("lane", "") for r in idle[args.max_lanes:]]
        idle = idle[:args.max_lanes]
        print(f"    └ examining {len(idle)} this pass; DEFERRED to the next pass "
              f"(bounded per-pass work): {', '.join(_deferred)}")
    for r in idle:
        lane = r.get("lane", "")
        cls = a.get(norm(lane))
        mark = cls if cls else "NO ASSIGNMENT -- skipped"
        print(f"    {lane:34} {mark}")

    if args.status:
        return

    print()
    # ⛔ THE OWNER'S PRIORITY, ENFORCED (2026-10-18). New issue work waits while un-owned PRs exist.
    # ⚠️ AND ONLY NEW ISSUE WORK DOES (review). `send_continue` lives INSIDE the loop below, so an
    # early return here stopped CONTINUE nudges to lanes that had stopped mid-work -- work already
    # claimed and in flight, the opposite of "new work". The gate now short-circuits the
    # claim/dispatch half only; the last-turn handling always runs.
    _gate = pr_first_gate()
    if _gate:
        print(f"  {_gate}")
    acted = 0
    for r in idle:
        lane = r.get("lane", "")
        ws = r.get("ws")
        cls = a.get(norm(lane))
        if not cls:
            continue
        if not ws:
            print(f"  SKIP {lane}: no workspace id in the verdict")
            continue
        if not cool(lane):
            print(f"  SKIP {lane}: inside the {args.cooldown}s cooldown")
            continue

        # ── THE LAST-TURN GATE: WHY did it stop? (see classify_last_turn) ────────────
        # This runs BEFORE the claim: a lane that stopped mid-work gets a CONTINUE,
        # not a new item, so nothing is claimed and no queue item is burned on it.
        try:
            choice, meta = classify_last_turn(r)
        except Exception as exc:                                     # noqa: BLE001
            choice, meta = None, {"error": str(exc)[:80]}
        conf = meta.get("confidence") if isinstance(meta, dict) else None
        if choice is None:
            print(f"  WITHHOLD {lane}: last-turn unreadable ({str(meta)[:80]}) — no dispatch, no continue")
            continue
        print(f"  LAST-TURN {lane}: {choice}" + (f" (conf={conf})" if conf else ""))
        if choice == "stopped_with_work_left":
            send_continue(lane, ws, dry=not args.apply)
            continue
        if choice == "asked_the_owner":
            print(f"  SKIP {lane}: it asked the owner — the answer queue owns it")
            continue
        # finished_the_work -> fall through to the claim
        # ⛔ NEW WORK ONLY FROM HERE (the owner's priority, enforced). A CONTINUE above is work this
        # lane has already claimed; a claim below would OPEN new work.
        if _gate:
            print(f"  SKIP {lane}: new issue work is SKIPPED while un-owned PRs exist")
            continue

        qfile = CLASS_QUEUE.get(cls, ("?",))[0]
        try:
            item, qpath = claim_next(lane, qfile)
        except QueueReadError as exc:
            # ⛔ A FAILED QUEUE READ IS NOT AN EMPTY QUEUE. Withhold THIS lane and say so --
            # never print "nothing left" (which is what the old fail-open did) and never
            # dispatch an item we could not verify. Bounded to one lane: the rest of the pass
            # proceeds, and the next tick retries this one.
            print(f"  READ-FAILED {lane}: {exc} — withholding this lane (NOT read as empty)")
            continue
        if not item:
            print(f"  SKIP {lane}: {qfile} has nothing left (read {qpath})")
            continue

        # ── IS THIS ITEM STILL REAL? The queue is a cache, and this is the moment it matters.
        st = pr_still_open(item)
        if st in ("MERGED", "CLOSED"):
            prnum = re.search(r"PR\s+(\d+)", item)
            prnum = prnum.group(1) if prnum else "?"
            subprocess.run([sys.executable, CLAIM, "free", lane, prnum],
                           capture_output=True, text=True, errors="replace")
            subprocess.run([sys.executable, CLAIM, "done", lane, prnum, "LANDED",
                            f"already {st} — verified live with gh at dispatch time; the queue row was stale"],
                           capture_output=True, text=True, errors="replace")
            print(f"  SKIP {lane}: {item.splitlines()[0][:60]} is already {st} — "
                  f"queue row stale, claim released, nothing sent")
            continue
        if st is None:
            print(f"  ⚠ could not read whether {item.splitlines()[0][:48]} is still open — "
                  f"dispatching anyway (an unreadable read is NOT evidence of absence)")

        # ── A TERMINAL VERDICT STAYS TERMINAL (#1563) ────────────────────────────────────
        # `claim.py next` has just served this item, and its resolution is last-write-wins: a
        # SKIPPED/FREE/unknown word written by ANY lane after another lane's FIXED/BLOCKED makes
        # the terminal row stop being the effective one. Seven instances measured on #1563, one
        # of them a STANDING OWNER DIRECTIVE (#5630) handed to a lane as fresh work. This is the
        # last gate before delivery, so the resurrection is refused HERE and the terminal verdict
        # is re-affirmed so claim.py stops offering it to the next lane too. The later
        # observation is recorded as an annotation -- what was seen, by whom, and when -- and the
        # verdict is unchanged. The reset path stays open: an explicit `REOPENED`/`REVIVED` row
        # with a reason re-opens the item, and `LIFTED` lifts an owner prohibition.
        pr_guard = pr_of(item)
        g = None
        if pr_guard:
            try:
                g = verdict_guard(qpath, pr_guard)
            except QueueReadError as exc:
                sh(["python3", CLAIM, "free", lane, pr_guard], timeout=60)
                print(f"  READ-FAILED {lane}: {exc} — withholding this lane (NOT read as empty)")
                continue
            except Exception as exc:                                # noqa: BLE001 — resolver absent
                # The guard could not be loaded (a box that has not yet been re-farmed).
                # FAIL-OPEN, LOUDLY: silently skipping the check is how a no-op gate reads green.
                print(f"  ⚠ VERDICT-GUARD UNAVAILABLE ({str(exc)[:120]}) — this pass runs WITHOUT "
                      f"the sticky-verdict check; a resurrected terminal item can be served (#1563)")
        else:
            # FAIL-OPEN, LOUDLY — the third and last path out of this gate. An item with no PR
            # number cannot be checked, and a check that skips SILENTLY is a check that reads
            # green over a queue it never examined. Say so, and deliver (see `no_pr_note`).
            print(no_pr_note(lane, item))
        if g is not None and not g.servable:
            wrote = refuse_resurrected(lane, pr_guard, g, args.apply)
            if wrote is None:
                print(f"  WOULD SKIP {lane}: {g.note}  (dry run wrote nothing)")
            else:
                print(f"  SKIP {lane}: {g.note} — NOT served; terminal re-affirmed as {wrote}, "
                      f"the later observation kept as an annotation")
            continue

        # ⛔ THE MESSAGE MUST CARRY THE *ROW'S* REMEDY, NOT THE LANE'S CLASS REMEDY.
        # MEASURED 2026-10-04: `4-REVIEW`, `5-FIX`, `6-SEMANTIC`, `7-DRAFT-PROMOTE` and `8-CLOSE`
        # ALL map to the shared REMEDY.tsv, and `claim_next` is class-AGNOSTIC (it hands back the
        # next unclaimed row from the file, whoever the lane is). So a lane on `4-REVIEW` can
        # claim an `8-CLOSE` row -- and was then told "FIRST refresh the base, THEN review at the
        # current head" for a PR whose entire remedy is "CLOSE it".
        # Column 6 of the queue row (the per-row remedy) was WRITTEN AND NEVER READ. Same class of
        # defect as a filter that logs a drop but does not perform it: the artifact looked right.
        # The row's class+remedy are authoritative for the row; the lane's only choose the FILE.
        # A mismatch is also the visible signal of the lane/class imbalance (measured: 12 lanes on a
        # 2-row class, 0 lanes on a 9-row class) -- so name it rather than resolving it silently.
        row_cls, row_remedy = cls, CLASS_QUEUE.get(cls, ("", "do the remedy"))[1]
        try:
            pn = re.search(r"PR\s+(\d+)", item) or re.search(r"(\d+)", item)
            pn = pn.group(1) if pn else None
            if pn:
                with open(qpath) as qf:
                    for line in qf:
                        f = line.rstrip("\n").split("\t")
                        # 7-col REMEDY format only; LANDABLE.tsv is 5-col and must not be read this way.
                        if len(f) >= 7 and f[1].strip() == pn:
                            row_cls = f[0].strip() or row_cls
                            if f[5].strip():
                                row_remedy = f[5].strip() + ((" -- " + f[6].strip()) if f[6].strip() else "")
                            break
        except Exception as e:
            print(f"  \u26a0 could not read the row remedy for {item[:40]} ({e}) -- using the class remedy")
        mismatch = (row_cls != cls)

        try:
            menu = outcome_menu(lane, pn, qpath)
        except Exception as exc:                                    # noqa: BLE001
            # Never emit an unverifiable menu silently: fall back to the widest vocabulary and
            # SAY SO, rather than print a class-blind list that may contain no terminal verdict.
            print(f"  \u26a0 VERDICT-MENU DEGRADED ({str(exc)[:100]}) -- emitting the full vocabulary")
            menu = (f'Record the outcome with: python3 {CLAIM} done "{lane}" {pn or "<pr>"} '
                    f'<LANDED|REFUSED|FIXED|BLOCKED|SKIPPED> "<reason>" ')
        msg = (f"ORCHESTRATOR (automatic queue dispatch): your next item is {item}.\n"
               f"Class: {row_cls} -- {row_remedy}.\n"
               + (f"NOTE: this row's class is {row_cls}, but your lane is assigned {cls}. "
                  f"The ROW's class+remedy above are authoritative for this row -- do that one, "
                  f"not your lane's usual job. (Your lane is on {cls} because of how the queue is "
                  f"sharded; the row still says what it needs.)\n" if mismatch else "")
               + f"Queue: {qpath}. " + menu + "\n")

        if not args.apply:
            # DRY RUN MUST NOT CONSUME. `claim_next` above has ALREADY taken the claim, so a
            # dry run that just prints would silently burn one item per lane per inspection —
            # the same class of defect as the cooldown bug fixed below in `cool()`, and the
            # same rule applies: INSPECTING A SYSTEM MUST NOT CHANGE IT. Give the claim back.
            sh(["python3", CLAIM, "free", lane, item.split()[1] if len(item.split()) > 1 else item], timeout=60)
            print(f"  WOULD SEND {lane} <- {item}  (claim released — dry run consumes nothing)")
            continue

        # safe-send.sh takes a brief FILE positionally: <workspace-uuid> <label> <file> [--force]
        # and it re-checks idleness at the moment of sending, because the verdict read above
        # can be seconds stale. Its exit codes are meaningful: 0 sent+CONSUMED,
        # 3 REFUSED because the lane is busy, anything else from the dispatcher.
        os.makedirs(TMPD, exist_ok=True)
        brief = os.path.join(TMPD, f"qd-{lane.replace('/', '_').replace(' ', '_')}.txt")
        with open(brief, "w") as f:
            f.write(msg)

        # TIMEOUT RAISED 240 -> 900 (2026-10-02). MEASURED: the send path is not failing on
        # EVIDENCE, it is failing on BUDGET. safe-send.sh runs lane-guard.py, which brackets the
        # pane with SEVERAL cmux reads (40s for one lane when cmux is healthy, and cmux has been
        # flapping at 1-16s per call). At 240s the caller cut the guard off mid-decision and got
        # `rc=None (timeout)` -- an answer of NOTHING, from which "busy" and "unreadable" and
        # "slow" cannot be told apart, so a genuinely idle lane was simply not fed. Two lanes
        # (5&9 MCP and SDK surface, 8 Hosted reliability) were lost to this in one pass while
        # the fleet sat at 18 idle. Raising the budget does NOT relax the guard: it lets the
        # existing gate ANSWER instead of timing out, so a real refusal still refuses.
        # ⛔ EXPLICIT merge at the CALL SITE, for the same reason as `send_continue` above: the
        # send verdict is read from one string, and safe-send.sh reports on stderr.
        rc, out, err = sh(["bash", SAFE_SEND, ws, lane, brief], timeout=900)
        out = (out or "") + (err or "")
        if rc == 0:
            print(f"  SENT {lane} <- {item}")
            mark_sent(lane)
            acted += 1
        elif rc == 3:
            # The lane is BUSY, or its state is UNKNOWN (which is NOT idle). Nothing was
            # delivered and nothing should be burned: release the claim so the item stays on
            # the queue, and do not start a cooldown, so the next tick retries it. This is
            # the gate working, not a failure.
            sh(["python3", CLAIM, "free", lane, item.split()[1] if len(item.split()) > 1 else item], timeout=60)
            print(f"  BUSY {lane}: safe-send refused (no positive no-WIP evidence); claim released, will retry")
        elif rc == 4:
            # AMBIGUOUS only when the OUTPUT says so. MEASURED 2026-10-01: a python-3.9
            # version-check exit also surfaced as rc=4 with NO send ever attempted, and
            # this branch's boilerplate hid the actual error text behind "a human must
            # inspect the composer". Print the output ALWAYS; the composer story is only
            # real when 'not consumed' appears in it.
            if "consum" not in (out or ""):
                sh(["python3", CLAIM, "free", lane, item.split()[1] if len(item.split()) > 1 else item], timeout=60)
                print(f"  FAILED-TO-START {lane} <- {item}: rc=4 but no send happened: {out.strip()[:90]} (claim released)")
                continue
            # cmux_dispatch reports 'sent-but-not-consumed' — the bytes WERE
            # written but no turn was confirmed, so the text may be sitting in the composer.
            # Do NOT release the claim and do NOT blind-retry: a second send would stack
            # another instruction on top of the first, which is the harm this cooldown
            # exists to prevent. Keep the claim so a later tick cannot hand this lane a
            # DIFFERENT item while the first may still be pending, and say so loudly.
            print(f"  AMBIGUOUS {lane} <- {item}: rc=4 sent-but-not-consumed. Claim KEPT, no retry. "
                  f"A human must inspect {lane}'s composer and release the claim deliberately.")
        else:
            # A claim without a delivery silently wastes one item of work, so give it back.
            sh(["python3", CLAIM, "free", lane, item.split()[1] if len(item.split()) > 1 else item], timeout=60)
            print(f"  FAILED {lane} <- {item}  rc={rc} {out.strip()[:70]} (claim released)")

    print()
    # ⛔ `dispatched 0` WITH NO DENOMINATOR AND NO REASON READS AS A HEALTHY EMPTY FLEET (2026-10-18,
    # the same defect pr-doctor.py's `_finish` removes). The pass now says 0 OF WHAT and WHY, so an
    # idle dispatch cannot be confused with a saturated fleet, a skipped gate or a blind read.
    _why = []
    if _gate:
        _why.append("un-owned PRs exist, so new issue work is SKIPPED")
    if _deferred:
        _why.append("%d lane(s) deferred by --max-lanes" % len(_deferred))
    if not args.apply:
        _why.append("dry run")
    print(f"{'(dry run) ' if not args.apply else ''}dispatched {acted} of {len(idle)} queued"
          + (f" — {'; '.join(_why)}" if _why else
             ("" if acted else " — no lane took an item (see the per-lane lines above)")))


if __name__ == "__main__":
    # ⛔ sys.exit IS LOAD-BEARING. `main()` returns 3 on an unreadable roster; a bare `main()`
    # discards that and the process exits 0 -- which is the whole "a failed read looks like a
    # healthy empty fleet" defect at the process boundary. Every non-zero exit in this file
    # (including the abort) reaches the caller ONLY through this call.
    sys.exit(main())
