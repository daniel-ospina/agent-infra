#!/usr/bin/env python3
"""The owner's objective, as ONE line the heartbeat and the lane-nudge both read.

THE OBJECTIVE IS QUALITATIVE (owner ruling on #6792, 2026-09-30T23:28:59Z):
    DRAIN THE PR BACKLOG -- land all the good work, WITHOUT DISCARDING USEFUL WORK -- and
    have a merge system fast and safe enough that this does not recur. CI speed is a KEY
    COMPONENT of draining the queue; a CI duration is not itself the objective.

The owner separated three kinds of thing, and they are NOT interchangeable:
  (a) OBJECTIVE  -- qualitative. Drives dispatch, and is what the verdict is ABOUT.
  (b) INDICATOR  -- a number always printed because it is useful, with NO pass/fail:
                    queue depth (`waiting`), its breakdown (`blocked`/`conflicting`/
                    `unstable`), and the CI critical path (`ci_crit_med`/`ci_crit_max`).
                    merges/24h and drain_days are the heartbeat's, on its queue line.
  (c) TARGET     -- OPTIONAL, and only where a benchmark or a defined value genuinely
                    exists. ONE survives here: `waiting < TARGET_PRS`, which is the
                    queue depth itself and was named by the owner. The CI minute figure
                    is NOT a target: it is `GUIDELINE_CI_MIN`, context printed beside the
                    verdict and never allowed to decide it.

So the verdict answers "is the QUEUE at target", with main health as a blocking
precondition, and -- since 2026-10-08 -- its DIRECTION: a queue above target that ROSE over
the last measured window is `REGRESSING`, never `ADVANCING`. Before that term the same
`ADVANCING` was emitted while the open count ran 12 -> 19 -> 21, i.e. a 75% backlog growth
read as progress. Owner, verbatim: "the <10min should be more of a guideline than an absolute
rule, the objective is more qualitative". Before this reframe the CI number was ANDed into
the verdict, so the whole fleet was steered to chase a figure the owner had demoted.

Why this exists at all: the heartbeat already answered "is a lane wedged" and
"is the merge queue the bottleneck", but nothing answered the owner's two
numbers, and nothing ever looked at whether MAIN ITSELF IS RED. Main red is not
a statistic -- it stops the merge queue, so no PR can drain at all. That was
found by hand on 2026-09-29 (main red on `python-ci-gate` at 9c4788400) after
hours of looking at lanes instead of at the tree.

LEAN BY DESIGN, and it follows the house pattern the other line-producers use
(`merge-queue.py`, `beta-progress.py`): print ONE final line, self-cache so the
heartbeat can call it every tick for free, never raise. It reads; it does not
act. Nothing dispatches from here.

TWO MEASUREMENT TRAPS THIS SCRIPT EXISTS TO AVOID, both hit for real:
  1. A run's `createdAt -> updatedAt` INCLUDES QUEUE WAIT. It read 44.3 min and
     was reported as "CI is 44 minutes" -- the real execution median was 5.7 min
     and the true critical path was 11.6-17.3 min. CI time here is JOB wall time.
  2. Per-attempt check-runs: one sha carries many attempts of a job, and a
     re-run ADDS an attempt without clearing one. Group by (app, workflow, job)
     and take the NEWEST BY `id`, then judge by POLARITY -- anything not in the
     green/non-red sets is RED, including conclusions GitHub has not documented.
     A missing check is NOT a green check.

Usage:  objective.py [--json] [--max-age 240]
Output: OBJECTIVE VERDICT=... prs_waiting=N ... main=RED|GREEN|UNKNOWN@sha ...
"""
from __future__ import annotations
import json, os, re, subprocess, sys, time
from collections import defaultdict
from datetime import datetime, timedelta, timezone

REPO = "daniel-ospina/tortoise"
STATE = os.path.expanduser("~/.pi/agent/state")
CACHE = os.path.join(STATE, "objective.last")

# (c) THE ONE TARGET. Kept as a real target because the owner named the value and it is
# the objective's own quantity -- queue depth, not a proxy for it. A target needs a defined
# value; here there is one.
TARGET_PRS = 10      # queue depth at target: fewer than 10 non-draft PRs waiting to land
# (b) A GUIDELINE, NOT A TARGET (owner ruling #6792, 2026-09-30). Printed with the CI
# indicators as context, and it must NEVER gate the verdict: a slow suite is a reason to
# improve the suite, not a verdict that the queue is not draining. Demoted from
# TARGET_CI_MIN, which the verdict used to AND in.
GUIDELINE_CI_MIN = 10.0

# The window over which a queue that ROSE is still evidence of the queue's direction.
# Direction is measured against the previous run's own `nondraft=` token (see
# _queue_grew_over_window) -- the same counter this file already prints and the same
# timestamp the reader derives `state_age` from, so no new metric and no new state file.
QUEUE_GROWTH_WINDOW_S = 3600

# Required status contexts on main. Hardcoded on purpose: one less API call per
# tick, and the set changes rarely.
#
# ⛔ RE-READ THIS FROM LIVE BRANCH PROTECTION, DO NOT TRUST THE DATE. The set CHANGED and
# this constant did not: `ai-review-gate` was ADDED between 2026-09-28 and 2026-09-29 and
# went unnoticed for a full day, because a hardcoded list cannot disagree with GitHub --
# it can only be silently wrong. The stale list made this script report `main=GREEN` while
# a NOW-REQUIRED check was failing, so the fleet's own readout was blind to a new gate.
# A cached required-set is a MONITOR OUTAGE that looks like an answer.
#   read 2026-09-28 (6): pricing-artifact docs test-isolation license-surface legal-e2e python-ci-gate
#   read 2026-09-29 (7): the six above + ai-review-gate                       <-- live, verified
# Verify with:
#   gh api repos/daniel-ospina/tortoise/branches/main/protection/required_status_checks --jq .contexts
# NOTE the asymmetry this reveals: main's `lint` job can be RED while main is still
# MERGEABLE, because `lint` is NOT required and is NOT a `needs:` of `python-ci-gate`.
# So `main=GREEN` here means "every REQUIRED context is green" -- it does NOT mean "main's
# tree is healthy". Read it as the former or not at all.
REQUIRED = ("pricing-artifact", "docs", "test-isolation", "license-surface",
            "legal-e2e", "python-ci-gate", "ai-review-gate")

GREEN = {"success", "neutral", "skipped"}
NON_RED = {"cancelled", "stale"}          # not green, but not evidence of failure
IN_FLIGHT = {"queued", "in_progress", "waiting", "requested", "pending"}


# WHY THIS EXISTS (measured 2026-09-29 04:58 UTC): every gh call in the fleet began
# failing with "API rate limit exceeded for user ID 81560491" -- 27 lanes plus the
# orchestrator share ONE account and therefore ONE budget, and overnight polling drained
# it. objective.py reported a bland UNKNOWN, which reads as "could not read the tree this
# tick" and invites a retry, when the truth is that THE WHOLE FLEET IS BLIND. An empty
# read and an absent thing are different facts and must not share a word.
GH_BLOCKED = None
GH_BLOCKED_BY = []          # WHICH read claimed blindness; the report must name it

# WHICH READS MAY DECLARE THE FLEET BLIND. The objective is defined over main's state and
# over the queue, so if either of those cannot be read no verdict can be formed and those
# two -- and ONLY those two -- may set GH_BLOCKED. Every other read (CI durations, and
# anything added later) is a METRIC: its failure degrades one number and must never be
# reported as "the fleet cannot see GitHub".
BLINDING_SURFACES = ("main", "queue")

# A TRANSPORT failure is a failure to REACH GitHub; a PARSE failure means GitHub answered and
# we could not read the answer. Only the first is blindness. The caller knows which it hit
# (a non-zero exit is the transport, an unparseable body is not), so it STATES it in
# `transport=` rather than leaving this function to guess from the text.
TRANSPORT_MARKERS = ("rate limit", "http 5", "http 4", "timed out", "timeout",
                     "could not resolve", "connection", "network", "tls", "ssl",
                     "temporary failure", "gateway", "unable to access")


def _note_gh_failure(text, surface, transport=True):
    """Record a read failure. Only a BLINDING surface, failing at the TRANSPORT, blinds.

    `surface` is mandatory on purpose. The earlier signature could not say which read
    failed, so a queue failure and a main failure produced the identical token
    `gh=UNREADABLE`, and a line reading `main=UNKNOWN@? gh=UNREADABLE queue=UNREADABLE`
    could not distinguish "the fleet is blind" from "one read failed before main was even
    attempted". Attribution was lost at exactly the moment it was needed: measured three
    times on 2026-09-29 the fleet was told `gh=UNREADABLE` while `gh api rate_limit`
    reported core 5000/5000 and every REST read succeeded -- the cause was one heavy
    `gh pr list` (GraphQL, 130+ PRs, `mergeStateStatus`) hiccuping, so the token named the
    wrong subsystem and each lane re-derived "is gh down?" from scratch.
    """
    global GH_BLOCKED, GH_LAST_ERROR
    GH_LAST_ERROR = text or ""
    if surface not in BLINDING_SURFACES:
        return                     # an optional read: it degrades a number, not the verdict
    low = (text or "").lower()
    if not transport or not any(m in low for m in TRANSPORT_MARKERS):
        return                     # GitHub answered and we mangled the answer: not blindness
    if surface not in GH_BLOCKED_BY:
        GH_BLOCKED_BY.append(surface)
    if "rate limit" in low:
        GH_BLOCKED = "RATE-LIMITED"
    elif GH_BLOCKED is None:
        GH_BLOCKED = "UNREADABLE"


GH_LAST_ERROR = ""


def gh(*args, paginate=False):
    """A REST read. Records WHY it failed, but never declares the fleet blind by itself.

    Only reads the objective actually depends on -- main's state, and the queue -- are
    allowed to do that, via `_note_gh_failure`. Measured 2026-09-29: the optional CI-duration
    sample kept re-setting the flag AFTER main had been read successfully over GraphQL, so a
    degraded metric read as a total blackout and the verdict stayed GH-BLOCKED while main's
    red was fully visible.
    """
    global GH_LAST_ERROR
    cmd = ["gh", "api"] + (["--paginate", "--slurp"] if paginate else []) + list(args)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
    if r.returncode != 0:
        GH_LAST_ERROR = (r.stdout or "") + (r.stderr or "")
        return None
    try:
        d = json.loads(r.stdout)
    except Exception:
        return None
    if paginate and isinstance(d, list):
        flat = []
        for page in d:
            if isinstance(page, dict) and "check_runs" in page:
                flat += page["check_runs"]
            elif isinstance(page, list):
                flat += page
        return flat
    return d


# NOTE the sha is INTERPOLATED, not a variable. `gh api graphql -f x=...` types every
# variable as String, and `object(expression:)` takes GitObjectID -- so `$sha:GitObjectID!`
# fails with "Type mismatch on variable $sha and argument expression (GitObjectID! / String)"
# and the whole read returns None. A String variable is not coerced here. The sha is a
# 40-char hex value read from our own repo, so inlining it is safe and is the only form
# that works over `gh`.
GQL_CHECKS = """
query($owner:String!, $name:String!) {
  repository(owner:$owner, name:$name) {
    object(expression:"%s") {
      ... on Commit {
        statusCheckRollup {
          contexts(first:100) {
            nodes { __typename
                    ... on CheckRun { databaseId name status conclusion detailsUrl }
                    ... on StatusContext { context state targetUrl } }
          }
        }
      }
    }
  }
}
"""


def gql_commit_checks(sha):
    """Main's check-runs over GRAPHQL, shaped like the REST read so callers do not care.

    WHY (measured 2026-09-29 05:00 UTC): the fleet exhausted GitHub's SECONDARY rate limit
    on the REST API -- every `gh api .../check-runs` returned "API rate limit exceeded for
    user ID 81560491" while `gh api rate_limit` still showed core 5000/5000, i.e. the hourly
    quota was NOT the constraint. But GraphQL has its OWN budget and was untouched: this
    query returned all 25 of main's check contexts at the same moment REST was refusing.
    So "the fleet is blind" was wrong in an avoidable way -- only ONE of the two transports
    was blocked. A read failure on one transport must not be reported as a property of the
    repository, and it must not be allowed to stop the fleet when the other transport is up.
    """
    q = GQL_CHECKS % sha
    r = subprocess.run(["gh", "api", "graphql", "-f", f"query={q}",
                        "-f", "owner=daniel-ospina", "-f", "name=tortoise"],
                       capture_output=True, text=True, timeout=90)
    if r.returncode != 0:
        return None
    try:
        nodes = (json.loads(r.stdout)["data"]["repository"]["object"]
                 ["statusCheckRollup"]["contexts"]["nodes"])
    except Exception:
        return None
    out = []
    for n in nodes:
        if n.get("context") is not None:            # a legacy StatusContext
            st = (n.get("state") or "").lower()
            out.append({"name": n.get("context"),
                        "status": "completed",
                        "conclusion": {"success": "success", "failure": "failure",
                                       "pending": "pending", "error": "failure"}.get(st, st),
                        "details_url": n.get("targetUrl") or ""})
        else:
            # `id` is CARRIED FROM `databaseId` AND IT IS NOT COSMETIC: `main_health` picks the
            # NEWEST ATTEMPT PER GROUP BY `id` (`max(items, key=lambda x: x.get("id") or 0)`).
            # With no id every check-run compared equal at 0, so `max` returned the FIRST element
            # -- the newest-attempt rule was silently defeated on the GraphQL path, which is the
            # PREFERRED transport. MEASURED 2026-10-04: a flaky `test (d)` failed, was re-run and
            # SUCCEEDED, and the superseded red was still the one in hand. That is exactly the
            # trap AGENTS.md names -- "a re-run ADDS a red, it does not clear one" -- and because
            # the heartbeat's own guidance is "main RED stops the merge queue", a stale red here
            # halts the drain. REST was unaffected (it returns `id`), which is why this only ever
            # bit when GraphQL, the preferred read, was the one that answered.
            out.append({"id": n.get("databaseId"),
                        "name": n.get("name"), "status": n.get("status"),
                        "conclusion": n.get("conclusion"),
                        "details_url": n.get("detailsUrl") or ""})
    return out or None


def main_sha():
    """The head of main, read over **`gh`** -- NOT `git`.

    \u26d4 WHY NOT `git` (2026-10-10, #7871). This used to run
    `git -C ~/Documents/GitHub/tortoise ls-remote origin refs/heads/main`. **macOS TCC denies a
    launchd process any read under `~/Documents`** -- a lesson this repo already carries verbatim in
    MEMORY.md: *"launchd bash CANNOT read symlinks into ~/Documents (macOS TCC EPERM) -- farmed
    scripts must be REAL copies under ~/.pi/agent/scripts"*. So under the heartbeat this returned
    `None`, `build()` printed `main=UNKNOWN@?`, and the `blind=` guard -- CORRECTLY -- refused to
    cache a failed read. **`objective.last` was therefore never written by ANY automated path**, so
    it aged 5m -> 12m -> 20m -> 27m -> 35m -> 42m, monotonic at one beat interval per tick.

    MEASURED from the loop: `main=UNKNOWN@?` on every tick since 10-09 18:37, while the SAME line's
    `open=`, `waiting=` and `ci_crit_med=` -- all `gh` reads -- populated normally. That asymmetry is
    the whole diagnosis: `gh` works under launchd here, `git` into ~/Documents does not.

    \u21d2 The refresh cadence was never the defect. **The producer could not succeed from the only
    context that runs it**, and no amount of refreshing can bound the age of a value that can never
    be written. Read main the same way the rest of this line is read.
    """
    r = gh(f"repos/{REPO}/commits/main")
    if isinstance(r, dict):
        sha = (r.get("sha") or "").strip()
        return sha or None
    return None


def main_health(sha):
    """(state, failing_required) judged by polarity on the newest attempt per group."""
    global GH_BLOCKED
    cr = gql_commit_checks(sha)
    if cr is not None:
        # a GraphQL read means the fleet can SEE -- so main withdraws its own claim, and
        # only its own: a queue failure recorded later in this same tick must survive.
        GH_BLOCKED_BY[:] = [s for s in GH_BLOCKED_BY if s != "main"]
        if not GH_BLOCKED_BY:
            GH_BLOCKED = None      # nobody else claims blindness, so the fleet can see
    else:
        cr = gh(f"repos/{REPO}/commits/{sha}/check-runs?per_page=100&filter=all", paginate=True)
    if cr is None:
        _note_gh_failure(GH_LAST_ERROR, "main")
        return "UNKNOWN", []
    red, flight = rollup_checks(cr)
    req_red = [c for c in REQUIRED if c in red]
    if req_red:
        return "RED", req_red
    if any(c in flight for c in REQUIRED):
        return "FLIGHT", []
    return "GREEN", []


# ⛔ A COUNT IS NOT A WINDOW (#7516). `per_page` alone let this function reach back EIGHT DAYS and
# return `36.7m(test (a))` -- the signature of the 2026-09-28 run at e12d676e8 -- while the composer
# printed a fresh 18.1m. Measured 2026-10-06 at main=52a2c1cf5: `ci_critical_path()` -> (36.733,
# 'test (a)') beside a printed `ci_crit_max=18.1m(test-slow (b))`. The question is "how long is CI on
# main NOW", so a run older than CRIT_MAX_AGE_H cannot answer it AT ALL -- and the honest answer is
# then UNKNOWN (build() omits the tokens when crit is None), never an older era's number.
CRIT_MAX_AGE_H = 6


def ci_critical_path(runs=15, min_jobs=8):
    """Slowest JOB wall time in runs that actually RAN -- queue wait excluded.

    Only runs with >= `min_jobs` jobs count. The newest runs are mostly queued or
    cancelled-before-start, and sampling THOSE returned 'ci_crit=1.0m(surface-guard)'
    -- technically the slowest job of a run that never ran a suite. The critical
    path lives in a full matrix run, so a partial run must not answer the question.
    """
    # ⛔ `branch=main` IS REQUIRED — the number is PRINTED NEXT TO A MAIN HEAD, so it must BE a main number.
    # Without this filter the window is the last `runs` runs of `python-ci.yml` ACROSS ALL BRANCHES, i.e. it
    # includes PR runs. Two measured consequences (2026-10-05, lane `2a Projection keys`):
    #   1. NON-REPRODUCIBLE AT A HEAD: at main=0420fb3eb, minutes apart, this reported
    #      `ci_crit_max=41.2m(test (h))` and then `19.2m(test (e))` -- the 15-run window slid under it as
    #      unrelated PR runs arrived. The actual worst job at that head (run 37323733659) was `test-carve-out (c)`
    #      at 12.1m, with every job 8.9-12.1m and every job starting within 28s of run creation.
    #   2. MISATTRIBUTED: the objective prints `main=GREEN@<sha> ... ci_crit_max=...`, so a PR run's worst job
    #      reads as main's. Six different legs were named across one session and each sent a lane to optimise a
    #      leg that was within 2m of every other.
    # "How long does a PR wait for CI" is a DIFFERENT question from "how long is main's suite" and needs its own
    # line if it is wanted; it must not share the one printed beside a main sha.
    # BOUND THE QUERY BY TIME, not just by count. With `per_page` alone the 15 most recent main runs
    # stretched back to 2026-09-28 (measured 2026-10-06), so an 8-day-old matrix answered "main now".
    _since = (datetime.now(timezone.utc)
              - timedelta(hours=CRIT_MAX_AGE_H)).strftime("%Y-%m-%dT%H:%M:%SZ")
    rl = gh(f"repos/{REPO}/actions/workflows/python-ci.yml/runs?branch=main&per_page={runs}"
            f"&created=%3E%3D{_since}")
    if not rl or not rl.get("workflow_runs"):
        return None, None, None
    per_run = []
    for r in rl["workflow_runs"][:runs]:
        # REQUIRE THE RUN ITSELF TO BE FINISHED. Skipping queued *jobs* is not enough: in a
        # partially-run matrix the only jobs with both timestamps are the CHEAP ones
        # (changes, surface-guard, manifest-integrity), so `worst` was satisfied by a run
        # whose suite had not started. Measured 2026-09-29 05:40 UTC, every recent run was
        # queued/pending with conclusion=None, and this function reported
        # `ci_crit_med=1.0m ci_crit_max=5.5m(test-slow (b))` -- a 6x drop from the 33-39m
        # real full-suite time, i.e. the CI half of the objective read as MET when the
        # suite had not run once. A duration is only a duration if the thing completed.
        if (r.get("status") or "").lower() != "completed":
            continue
        d = gh(f"repos/{REPO}/actions/runs/{r['id']}/jobs?per_page=100")
        jobs = (d or {}).get("jobs", [])
        if len(jobs) < min_jobs:
            continue
        # THE SUITE MUST HAVE ACTUALLY RUN. Job COUNT was never evidence of that: a run whose
        # matrix was cancelled early still carries all 12 job records, and one where only the
        # cheap drift checks ran reports its worst job as `manifest-integrity` (0.2m). Measured
        # 2026-09-29 06:05 UTC this produced `ci_crit_max=3.0m(manifest-integrity)`, the THIRD
        # false CI number from this one function (after 1.0m(surface-guard) and 5.5m(test-slow)).
        # The invariant that actually answers "how long does a PR wait for CI" is: the slowest
        # job of a run that contains a COMPLETED suite job -- the suite being every job whose
        # name begins with `test`. Without such a job the run cannot answer the question at all.
        # ...and "completed" is not "ran" either. A CANCELLED matrix gives every suite job a
        # start and an end, ~3 minutes apart, which satisfied the previous check and produced
        # `ci_crit_max=3.0m(manifest-integrity)` -- the fourth variant of the same false
        # number. A suite job answers the question only if it reached a CONCLUSION that means
        # it executed: success or failure. cancelled / skipped / neutral mean the work never
        # happened, so they cannot describe how long a PR waits.
        RAN = ("success", "failure")
        suite_ran = any((j.get("name") or "").startswith("test")
                        and (j.get("conclusion") or "").lower() in RAN
                        for j in jobs)
        if not suite_ran:
            continue
        worst, worst_name = 0.0, "?"
        for j in jobs:
            if (j.get("conclusion") or "").lower() not in RAN:
                continue
            if not (j.get("started_at") and j.get("completed_at")):
                continue
            try:
                a = datetime.fromisoformat(j["started_at"].replace("Z", "+00:00"))
                b = datetime.fromisoformat(j["completed_at"].replace("Z", "+00:00"))
            except Exception:
                continue
            m = (b - a).total_seconds() / 60.0
            if m > worst:
                worst, worst_name = m, j.get("name", "?")
        if worst:
            per_run.append((worst, worst_name, r.get("created_at")))
    if not per_run:
        return None, None, None
    # ⛔ A `runs`-SIZED WINDOW IS NOT A TIME WINDOW, and that is what made this number unreadable.
    # MEASURED 2026-10-05: with no branch filter this enumerated the last 15 runs of `python-ci.yml` across ALL
    # branches -- a span of about an HOUR -- and reported `ci_crit_max=41.2m(test (h))`, then `19.2m(test (e))`
    # minutes later at the SAME main head, as unrelated PR runs slid through the window. Adding `branch=main`
    # did NOT fix it and made the printed figures WORSE (`med=36.7m max=38.5m(test (a))`), because main runs
    # are far rarer: 15 of them reach back WEEKS, across the shard split, into an era when the suite really was
    # ~36m. In both cases the reader is shown a HIGH-WATER MARK from an arbitrary era beside a main sha, and
    # reads it as "main now". Actual main at that sha (run 37323733659) was `test-carve-out (c)` 12.1m, every
    # job 8.9-12.1m, every job started within 28s of run creation.
    # THE QUESTION THE OBJECTIVE ASKS IS "how long is CI on main NOW" -- so answer THAT: the NEWEST qualifying
    # main run. It is reproducible at a head, it matches the sha printed beside it, and it cannot be moved by
    # unrelated traffic. `per_run` is appended newest-first (the runs list is newest-first), so [0] is newest.
    newest = per_run[0]
    # Even inside the window a run can be hours old. If the NEWEST qualifying run is stale, refuse to
    # answer rather than serving an older era's figure as if it described now.
    try:
        _age_h = (datetime.now(timezone.utc)
                  - datetime.fromisoformat(newest[2].replace("Z", "+00:00"))
                  ).total_seconds() / 3600.0
    except Exception:
        return None, None, None
    if _age_h > CRIT_MAX_AGE_H:
        return None, None, None
    return newest[0], newest[1], newest[0]


def _gh_retry(argv, attempts=3, timeout=120):
    """A transient 5xx from GitHub is NOT fleet blindness.

    MEASURED 2026-10-03 16:53: the heartbeat reported `main=UNKNOWN@? gh=UNREADABLE(queue)
    queue=UNREADABLE` and `VERDICT=UNKNOWN (merge-rate read failed)` from a SINGLE attempt,
    while `gh api` was intermittently returning GitHub's OWN error, "No server is currently
    available to service your request" -- on REST 4/5 and GraphQL 5/5 successes, seconds
    apart, with rate limits untouched at core 5000/5000 and graphql 5000/5000. So the
    fleet was told it was BLIND by a blip that a single retry absorbs (4/5 -> ~25/25).

    A retry is the right shape because the failure is upstream and retryable, and because
    `_note_gh_failure` treats a transport failure on `main`/`queue` as a verdict-gating
    event: without this, one 5xx blanks the whole objective line. Only a TRANSPORT failure
    is retried -- a successful-but-unparseable answer is a real fact and is returned as-is.
    """
    last = None
    for i in range(attempts):
        last = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        if last.returncode == 0:
            return last
        low = ((last.stdout or "") + (last.stderr or "")).lower()
        transient = any(m in low for m in (
            "no server is currently available", "gateway timeout", "http 5", "server error",
            "timed out", "timeout", "503", "504", "try again", "temporarily unavailable"))
        if not transient or i == attempts - 1:
            return last
        time.sleep(2 * (i + 1))
    return last


SURFACE_PATHS = ("tortoise/sdk.py", "tortoise/tool_registry.py",
                 "config/surface-manifest.yml")
# The owner-designed ACTION vocabulary (2026-10-10), cheapest-and-highest-payoff FIRST.
# `call-rail` first: it is the win -- all 7 required green AND a clean attestation at
# the current head, i.e. `bash scripts/admin-merge.sh <PR>` lands it with zero code work.
# `rerun-checks` and `resolve-conflict` sit ABOVE `record-review` because a missing check
# tells you NOTHING and a rebase CHANGES THE HEAD, staling any attestation.
CLASS_ORDER = ("call-rail", "blocked-by-rail", "rerun-checks", "resolve-conflict",
               "record-review", "fix-ci")
# ⛔ RAIL_GATES MUST TRACK `scripts/admin-merge.sh` -- AND `call-rail` MEANS "THE RAIL WILL
# ACCEPT IT", NOTHING WEAKER. The rail refuses on MORE than the 7 branch-protection contexts.
# MEASURED 2026-10-10: `call-rail=1: #7924 (STUCK 3 beats)` sent a lane to call a rail that
# REFUSED #7924 for flip-gate/drift-guard -- three hours of `call-rail` on the line with NOTHING
# landable behind it, which is how a fleet learns to distrust the token. The note that
# `drive`/`drift-guard`/`sigpipe-guard` are "never blockers" is TRUE for the 7 required contexts
# and FALSE for the rail; the instrument inherited the wrong one.
RAIL_GATES = ("flip-gate", "drift-guard", "provenance")


# ⛔ A TOKEN THAT NAMES AN ACTION BUT NOT ITS OBJECT IS A REPORT, NOT AN INSTRUCTION.
# A lane reading `call-rail=3` had to RE-DERIVE WHICH THREE -- re-run the check rollup, re-read
# the attestation files, and decide -- which is the exact work the instrument exists to remove.
# So these classes name their PRs. `fix-ci` deliberately does NOT (it is often 6+ PRs and would
# swamp the line with the one class that needs no triage to act on).
NAMED_CLASSES = ("call-rail", "blocked-by-rail", "record-review", "resolve-conflict",
                 "rerun-checks")
STUCK_FILE = os.path.join(STATE, "call-rail-stuck.json")


def _stuck_bump(prs):
    """Consecutive beats each `call-rail` PR has waited, persisted across beats.

    ⛔ A TOKEN THAT REPEATS VERBATIM TEACHES THE READER TO SKIP IT. MEASURED 2026-10-10:
    `call-rail=1` sat UNCHANGED on three consecutive beats while a finished, attested PR stayed
    unlanded for 90 minutes, and a later SHA-bound read found THREE such PRs. The instrument
    already holds state between beats, so the second time it says the same thing it must say it
    LOUDER -- not again. Tonight's most expensive failure mode was a PR that was finished and
    left: #7906 35m, #7922 25m, #7904 and these three ~90m, every one green and attested.
    """
    prev = {}
    try:
        with open(STUCK_FILE) as fh:
            prev = json.load(fh)
    except Exception:
        prev = {}
    cur = {str(n): int(prev.get(str(n), 0)) + 1 for n in prs}
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(STUCK_FILE, "w") as fh:
            json.dump(cur, fh)
    except Exception:
        pass
    return cur


def _class_token(name, count, prs=None, stuck=None):
    """`call-rail=3: #7960 #7924 #7920 (STUCK 3 beats — land or say why)`.

    The count is the priority signal and the numbers are the WORK. Escalation uses the
    longest-waiting PR, so one old stuck PR alarms even beside a freshly-arrived one.
    """
    tok = f"{name}={count}"
    if prs and name in NAMED_CLASSES:
        tok += ": " + " ".join(f"#{n}" + (f"({w})" if w else "") for n, w in prs)
    if name == "call-rail" and prs and stuck:
        n = max(stuck.get(str(p), 0) for p, _w in prs)
        if n >= 2:
            tok += f" (STUCK {n} beats — land or say why)"
    return tok


def per_pr_checks(sha):
    """Per-PR check-runs over REST -- the COMPLETE surface, every attempt, and NO DEDUPING.

    ⛔ DO NOT BUILD A VERDICT ON `statusCheckRollup`. The GraphQL rollup does not reliably
    return every attempt: `#8009` was reported `blocked-by-rail(drift-guard)` while its head
    `05ecc34e` carried EXACTLY ONE drift-guard check-run and it was `success` (id 114342292995)
    -- the rollup simply had not returned it, and an ABSENT gate was read as a FAILING one.
    A false positive on an ACTION token sends a lane on an impossible errand: it burned ~3h on
    `#7924` before anyone checked the rail. `filter=all` MUST be a QUERY STRING -- as form
    fields (`-f filter=all`) it silently returns a PARTIAL set, which is how this was missed.
    """
    cr = gh(f"repos/{REPO}/commits/{sha}/check-runs?per_page=100&filter=all", paginate=True)
    return cr if cr is not None else gql_commit_checks(sha)


def rail_block_reason(red, flight, seen):
    """The first rail gate that is PROVEN non-green, or None. NEVER absence -- see below.

    ⛔ ABSENCE IS NOT EVIDENCE OF A FAILURE. Treating a gate missing from the read as a block
    is what produced the `#8009` phantom: `not in seen` is equally satisfied by a gate that is
    GREEN and by a read that was INCOMPLETE, and those are opposite conclusions. Only a check
    that is actually RED (or in flight) may declare a rail block.
    """
    # Prefer a gate that FAILED over one still in flight -- and never report one that simply
    # did not run. Reported in plain list order, the tool once named `flip-gate` while the rail
    # named `drift-guard` on the SAME PR, because `flip-gate` was merely ABSENT from that head.
    for pool in (red, flight):
        for g in RAIL_GATES:
            if g in pool:
                return g
    return None


def rollup_checks(cr):
    """(red, flight) name-sets by POLARITY on the NEWEST attempt per (app, workflow, name).

    A re-run ADDS a check-run; it does not clear one -- so the newest attempt by `id` is the
    only honest read. Grouping by (app, workflow, job name) keeps two workflows that share a
    job name apart, and `id` (not `started_at`, which is nullable) breaks the tie. Every
    conclusion that is neither green nor explicitly non-red is RED -- INCLUDING one GitHub has
    not documented, and a NULL one: read the group by polarity, never by an allow-list of the
    failures you happen to expect.
    """
    groups = defaultdict(list)
    for c in cr:
        app = (c.get("app") or {}).get("slug") or "?"
        du = c.get("details_url") or ""
        wf = "run" + du.split("/actions/runs/")[1].split("/")[0] if "/actions/runs/" in du else "?"
        groups[(app, wf, c.get("name"))].append(c)
    red, flight = set(), set()
    for (_a, _w, name), items in groups.items():
        newest = max(items, key=lambda x: x.get("id") or 0)
        st = (newest.get("status") or "").lower()
        concl = (newest.get("conclusion") or "").lower()
        if st and st != "completed":
            flight.add(name)
        elif concl in GREEN or concl in NON_RED:
            continue
        else:
            red.add(name)
    return red, flight


def attestation_clean(number, head_sha):
    """True iff a review record exists for this PR AT THIS HEAD with verdict `clean`.

    Read from the head-bound record the review gate itself writes -- never from the PR body,
    which is mutable and whose edit WIPES the attestation (agent-infra #1224). An attestation
    for a DIFFERENT head is not an attestation: a rebase stales it, which is why this compares
    `head_sha` rather than merely finding a file.
    """
    if not number or not head_sha:
        return False
    base = os.path.expanduser("~/.pi/agent/reviews")
    for name in (f"{REPO.replace('/', '-')}-{number}.json",
                 f"daniel-ospina-tortoise-{number}.json"):
        try:
            with open(os.path.join(base, name)) as fh:
                d = json.load(fh)
        except Exception:
            continue
        return (str(d.get("head_sha") or "") == head_sha
                and str(d.get("verdict") or "").lower() == "clean")
    return False


def touches_surface(p):
    """True iff the diff touches a file only the USER may authorise a change to."""
    for f in (p.get("files") or []):
        path = f.get("path") if isinstance(f, dict) else str(f)
        if path in SURFACE_PATHS:
            return True
    return False


def classify_pr(pr, cr, att_clean):
    """The ONE action class for a non-draft PR, FIRST MATCH in CLASS_ORDER, or None if unread.

    Pure on purpose: `cr` is a check-run list ALREADY READ and `att_clean` the attestation
    verdict, so the classification is testable without touching GitHub. `None` (a miss) is
    NOT `fix-ci` -- an unreadable PR must never be counted as work, or a blind read would
    manufacture a queue of failures.
    """
    if cr is None:
        return None
    red, flight = rollup_checks(cr)
    seen = {c.get("name") for c in cr if c.get("name")}
    req_seen = [n for n in REQUIRED if n in seen]
    nongreen = [n for n in REQUIRED if n in red or n in flight or n not in seen]
    # ⛔ `ai-review-gate` IS DIFF-BOUND, SO IT MUST NOT GATE `call-rail`. It goes RED BY
    # CONSTRUCTION on any PR whose record was written AFTER its last run -- MEASURED 2026-10-10:
    # red on 8 of 11 open PRs, INCLUDING #7960, which already carried a CURRENT CLEAN
    # attestation. Requiring all 7 green therefore made `call-rail` DEAD CODE and dropped a
    # fully-attested, one-call-from-landing PR into `record-review` -- i.e. it told a lane to
    # RE-RECORD a head that was already recorded, and RE-ATTESTING AN UNCHANGED HEAD DILUTES
    # THE EVIDENCE (and re-recording is what leads a lane to edit the PR body, which WIPES the
    # attestation). The gate's real condition is SEMANTIC -- "a clean review is recorded at this
    # head" -- and the head-bound attestation FILE states that authoritatively, so the check-run
    # is only a stale PROXY for `ai-review-gate` and never for the other six.
    nongreen_x = [n for n in nongreen if n != "ai-review-gate"]
    # 1. call-rail -- every required check EXCEPT `ai-review-gate` is green AND a clean
    #    attestation exists at the CURRENT head AND the RAIL ITSELF would take it. The last
    #    clause was missing: an attested PR the rail refuses is a NAMED defect, not "not ready".
    if not nongreen_x and att_clean:
        return "blocked-by-rail" if rail_block_reason(red, flight, seen) else "call-rail"
    # 2. rerun-checks -- NO required check EVER ran at this head (`drive`/`drift-guard`/
    #    `sigpipe-guard` being red cannot reach here: they are not in REQUIRED).
    if not req_seen:
        return "rerun-checks"
    # 3. resolve-conflict -- GitHub says DIRTY.
    if (pr.get("mergeStateStatus") or "") == "DIRTY":
        return "resolve-conflict"
    # 4. record-review -- every required check EXCEPT `ai-review-gate` is green and there is NO
    #    current clean attestation at this head. This is the LEGITIMATE case, and it is the exact
    #    complement of arm 1: the ONLY difference between landing a PR and re-recording it is
    #    whether the attestation at THIS head exists, which is why the file -- not the check-run
    #    -- decides. (An all-green `ai-review-gate` with a SUPERSEDED record lands here too: a
    #    green gate at an old head is evidence about that head, not this one.)
    if not nongreen_x and not att_clean:
        return "record-review"
    # 5. fix-ci -- any OTHER required check non-green: real code work.
    return "fix-ci"


def classify_queue(non):
    """(Counter of CLASS_ORDER, surface_count) or (None, surface) when ANY PR was unreadable.

    FIRST MATCH makes the five buckets a PARTITION of `nondraft`, asserted here rather than
    assumed: the token is omitted entirely when the sum does not reconcile, because a partial
    sum that still LOOKS like a partition is worse than no token at all.
    """
    classes, surface, unread = defaultdict(int), 0, 0
    by_class = defaultdict(list)
    for p in non:
        head = p.get("headRefOid") or ""
        cr = per_pr_checks(head)
        k = classify_pr(p, cr, attestation_clean(p.get("number"), head))
        if k is None:
            unread += 1
        else:
            classes[k] += 1
            why = None
            if k == "blocked-by-rail" and cr:
                _red, _fl = rollup_checks(cr)
                why = rail_block_reason(_red, _fl,
                                        {c.get("name") for c in cr if c.get("name")})
            elif k == "fix-ci" and cr:
                # NAME THE FAILING CHECK, so the work is obvious without re-deriving it. Job
                # names (e.g. `test (slow (b))`) matter: they say whether this is a real break
                # or the load-dependent timeout class (#5049).
                _red, _fl = rollup_checks(cr)
                why = ",".join(sorted(n for n in _red
                                      if n != "ai-review-gate" and n not in RAIL_GATES)) or "?"
            by_class[k].append((p["number"], why))
        if touches_surface(p):
            surface += 1
    if unread or sum(classes[k] for k in CLASS_ORDER) != len(non):
        return None, surface, {}      # PARTITION INVARIANT -- omit rather than mislead
    for k in by_class:
        by_class[k].sort()
    return classes, surface, dict(by_class)


def queue():
    r = _gh_retry(["gh", "pr", "list", "--repo", REPO, "--state", "open",
                   "--limit", "400", "--json",
                   "number,isDraft,mergeable,mergeStateStatus,headRefOid,files"])
    if r.returncode != 0:
        _note_gh_failure((r.stdout or "") + (r.stderr or ""), "queue")
        return None
    try:
        prs = json.loads(r.stdout)
    except Exception:
        # The transport WORKED and the answer was unreadable. That is not fleet blindness,
        # so `transport=False` -- and the queue still reports itself UNREADABLE locally.
        _note_gh_failure(f"unparseable queue response: {r.stdout[:400]}", "queue",
                         transport=False)
        return None
    non = [p for p in prs if not p["isDraft"]]
    from collections import Counter
    ms = Counter(p.get("mergeStateStatus") or "?" for p in non)
    # ⛔ AN UNREAD STATE MUST NEVER PRINT AS A ZERO. `mergeStateStatus` is computed LAZILY by
    # GitHub and reads UNKNOWN for the WHOLE repo while it recomputes -- measured 2026-10-01:
    # 75 of 82 open non-draft PRs read UNKNOWN at 11:47Z, and the SAME three PRs read BLOCKED
    # from BOTH `gh pr view` and `gh pr list` two minutes later once the recompute finished
    # (so it is a transient blind spot, not a wrong field -- the REST list endpoint returns
    # null here and is no better). Counting only BLOCKED/DIRTY/UNSTABLE silently DROPS those,
    # so a blind read printed ZEROS for both: a FALSE ALL-CLEAR, the one wrong
    # answer this instrument can give (same fail-open class as GH_BLOCKED, #6142).
    _KNOWN = {"BLOCKED", "DIRTY", "UNSTABLE", "CLEAN", "BEHIND", "HAS_HOOKS"}
    unknown = sum(c for k, c in ms.items() if k not in _KNOWN)
    classes, surface, by_class = classify_queue(non)
    return {"open": len(prs), "drafts": len(prs) - len(non), "nondraft": len(non),
            "dirty": ms.get("DIRTY", 0),
            "unstable": ms.get("UNSTABLE", 0), "unknown": unknown,
            "classes": classes, "by_class": by_class, "surface": surface}


def _previous_sample():
    """(nondraft, age_seconds) from the last MEASURED line in the cache, or None.

    Reuses the cache this script already writes: line 1 is the measurement timestamp (the
    same counter `state_age` is derived from) and line 2 carries the `nondraft=` token.
    That previous record is the ONLY prior queue depth that exists, so direction is read
    from it rather than invented -- and an absent/unreadable sample leaves the direction
    UNKNOWN instead of fabricating a change.
    """
    try:
        with open(CACHE) as fh:
            lines = [ln.strip() for ln in fh if ln.strip()]
        ts = datetime.fromisoformat(lines[0].replace("Z", "+00:00"))
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        age = (datetime.now(timezone.utc) - ts).total_seconds()
        m = re.search(r"\bnondraft=(\d+)", lines[1])
        return (int(m.group(1)), age) if m else None
    except Exception:
        return None


def _queue_grew_over_window(now_nondraft, prev):
    """True iff the open non-draft count ROSE across the last measured window.

    The queue's direction is a first difference of the counter this file already measures
    (`nondraft`), taken against the previous run's sample. It is deliberately NOT inferred
    from `merged_24h`/`drain_days`: those are a flow/stock ratio on another line, and a
    large `drain_days` is equally consistent with a STEADY deep queue (which must keep its
    existing ADVANCING semantics) as with a growing one -- so they cannot answer this.

    Direction is only claimed while the previous sample is recent enough to be the same
    queue: past QUEUE_GROWTH_WINDOW_S the comparison is still "bigger", but it is not
    evidence the queue grew *now*, and a verdict may not rest on it.
    """
    if not prev or now_nondraft is None:
        return False
    then, age = prev
    if age is None or age > QUEUE_GROWTH_WINDOW_S:
        return False
    return now_nondraft > then


def build(prev=None):
    sha = main_sha()
    mstate, mfails = main_health(sha) if sha else ("UNKNOWN", [])
    crit, crit_job, crit_max = ci_critical_path()
    q = queue()

    parts = [f"main={mstate}@{sha[:9] if sha else '?'}"]
    if GH_BLOCKED:
        # NAME THE SURFACE. An unattributed `gh=UNREADABLE` is what sent three separate lanes
        # looking for an outage that was not there.
        parts.append(f"gh={GH_BLOCKED}({'+'.join(GH_BLOCKED_BY) or '?'})")
    if mfails:
        parts.append("failing_required=" + ",".join(mfails))
    if q:
        # `waiting` must mean what the OWNER's target means: the QUEUE DEPTH of PRs that
        # still have to merge = open non-draft PRs. It was wired to `blocked + unstable`
        # (PRs stuck AT the gate), which is a different and much smaller set: on 2026-09-30
        # it read waiting=3 while 109 non-draft PRs were open, so the verdict compared an
        # at-the-gate count against a queue-depth target and reported ADVANCING on a queue
        # that was 11x the target. `blocked`/`conflicting`/`unstable` are kept as NAMED
        # diagnostics -- they are the useful breakdown of a queue -- but they no longer
        # masquerade as the queue itself.
        parts.append(f"open={q['open']} drafts={q['drafts']} nondraft={q['nondraft']}")
        # ── THE ACTION VOCABULARY, in place of `blocked` (owner-designed, 2026-10-10) ──
        # The deleted token counted `mergeStateStatus=BLOCKED`, which GitHub emits for SEVERAL
        # unrelated conditions, so it needed a sentence of apology ("counter(not a work count)")
        # to say so -- and A VOCABULARY THAT NEEDS AN APOLOGY IS THE WRONG VOCABULARY.
        # MEASURED 2026-10-10 on 10 non-draft PRs: 8 read BLOCKED and 2 DIRTY, and of the 8,
        # FOUR had `ai-review-gate` as their ONLY red -- i.e. RECORD IT, zero code work -- and
        # ONE had never run a required check at all. The word was concealing the CHEAPEST
        # LANDINGS on the board. Every token below names an ACTION, never a state, and zero
        # tokens are OMITTED: an absent token is honest, a printed zero is a claim.
        # `waiting` is unchanged and load-bearing -- it is the queue depth the verdict compares
        # against `TARGET_PRS`.
        _do = q.get("classes")
        if _do:
            _bc = q.get("by_class") or {}
            _stuck = _stuck_bump([n for n, _w in (_bc.get("call-rail") or [])])
            seg = " ".join(_class_token(k, _do[k], _bc.get(k), _stuck)
                           for k in CLASS_ORDER if _do.get(k) and k != "fix-ci")
            # ── IN-PROGRESS: A FIXABLE CI FAILURE IS PROGRESS, NOT BLOCKAGE ──────────────
            # Owner, verbatim: "whenever our tests discover something that needs fixing before
            # running CI again, you label it as blocked instead of doing the work that is
            # needed ... having to fix things is a NATURAL PART OF THE CI PROCESS." He was
            # right, and it was a design defect, not a reporting nit: `fix-ci=13` rendered a
            # routine repair step as a wall, the orchestrator reported a wall, and NOTHING in
            # the system did the work -- 25 PRs sat while every beat printed a count. A PR whose
            # next step is "fix the failing test" HAS AN OWNER AND AN ACTION; it is MOVING.
            # Only ASK-USER and a genuine external wait are ever "not moving".
            # Each entry names WHICH check failed AND how many PRs, so a lane knows what to open.
            if _do.get("fix-ci"):
                _cnt = defaultdict(int)
                for _num, _why in (_bc.get("fix-ci") or []):
                    for _nm in (_why or "?").split(","):
                        if _nm:
                            _cnt[_nm] += 1
                if _cnt:
                    seg += " IN-PROGRESS: fixing " + " ".join(
                        f"{n}={c}" for n, c in sorted(_cnt.items(), key=lambda kv: (-kv[1], kv[0])))
            if q.get("surface"):
                # An OVERLAY, not a sixth bucket: it does not break the partition, because a
                # surface change can also need work. It names the one action only the USER may take.
                seg += f" | ASK-USER: surface={q['surface']}"
            parts.append(f"waiting={q['nondraft']} prs: {q['nondraft']} nondraft | DO: {seg}")
        else:
            # `classes` is None when ANY PR's checks were unreadable, so no partition is printed.
            parts.append(f"waiting={q['nondraft']}")
        _u = q.get("unknown") or 0
        _blind = _u > 0 and 2 * _u >= max(1, q["nondraft"])
        if _u:
            parts.append(f"mergeable_state_unknown={_u}")
        if _blind:
            # A ZERO FROM A BLIND READ IS NOT A CLEARANCE. Kept from the deleted pair: the
            # fail-closed job belongs to whatever token stands where the zeros used to.
            parts.append(f"queue_read=BLIND({_u}/{q['nondraft']} unread) -- the DO: counts are NOT a clearance")
        # ⛔ `blocked` IS DELETED AS A TOKEN, AND SO IS ITS CAVEAT. Do not re-add either.
        # Anything that needs a sentence of apology to be read correctly is the wrong vocabulary;
        # the ACTION tokens above say what to DO, which is what the beat exists to convey.
        waiting = q["nondraft"]
    else:
        parts.append("queue=UNREADABLE")
        waiting = None
    if crit:
        # INDICATOR, not a target (see GUIDELINE_CI_MIN). MEDIAN critical path and the worst
        # seen -- the worst is what a PR actually waits for, because one slow shard is the
        # path. Reported so the suite CAN be improved; it does not decide the verdict.
        parts.append(f"ci_crit_med={crit:.1f}m ci_crit_max={crit_max:.1f}m({crit_job})")
        parts.append(f"ci_guideline={GUIDELINE_CI_MIN:.0f}m:"
                     f"{'over' if (crit_max and crit_max > GUIDELINE_CI_MIN) else 'within'}")

    # -- the verdict: ONE word the heartbeat can alert on ----------------------
    if GH_BLOCKED == "RATE-LIMITED":
        verdict = "GH-BLOCKED"       # NOT a property of the tree: the fleet cannot read
    elif mstate == "RED":
        verdict = "BLOCKED"          # nothing can drain; own the tree, not the lanes
    elif q is None or mstate == "UNKNOWN":
        verdict = "UNKNOWN"          # never extrapolate from an unreadable surface
    # The verdict is about the QUEUE. `crit_max` is deliberately NOT a term here: CI time is
    # an indicator (see GUIDELINE_CI_MIN), and the owner demoted it from target to guideline
    # on #6792, so it must not be able to flip this word.
    elif waiting is not None and waiting < TARGET_PRS:
        verdict = "AT-TARGET"
    # ⛔ A DEEP QUEUE THAT IS GROWING IS NOT PROGRESS (measured 2026-10-08).
    # The verdict was main-green AND (queue above target), with NO direction term, so the
    # SAME word `ADVANCING` was emitted while the open count ran 12 -> 19 -> 21 (drafts
    # 4 -> 4 -> 6): the backlog grew ~75% and the instrument reported the one outcome the
    # objective ("DRAIN THE PR BACKLOG") exists to detect as if it were success. That is
    # how every lane could be locally correct while nothing landed. The word is now a
    # DIRECTION, not a state: `REGRESSING` when the open non-draft count rose across the
    # last measured window, `ADVANCING` only when it did not.
    elif _queue_grew_over_window(waiting, prev):
        verdict = "REGRESSING"
    else:
        # Readable, main green, queue still above target, and NOT growing over the window:
        # steady or shrinking. (Named ADVANCING since 2026-09-29; the word is kept for
        # interface stability.)
        verdict = "ADVANCING"
    return f"OBJECTIVE VERDICT={verdict} " + " ".join(parts)


# ⛔ A VERDICT MAY NOT BE SERVED STALER THAN THIS (measured 2026-10-06, #4844).
# `max_age` protects the API by serving the last line for up to 15 minutes, and it validates that
# line by `main=<sha>`. A sha-keyed check CANNOT see a check that REGRESSES on an unchanged head:
# the fleet brief served `main=GREEN@52a2c1cf5` while the tree was RED (required `python-ci-gate`
# failing; `test (f)` 1 failure / 1912 tests, a transient health-probe miss). A reader taken in by
# that line has no reason to own the tree. So the window that guards the API is bounded separately
# from the truth of the verdict token: past this age the line is RECOMPUTED, not served.
VERDICT_SERVE_MAX_S = 120


def _res_run(cmd, timeout=30):
    """stdout, or None -- a measurement that failed is None, NEVER an empty string or a zero."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return None


def _cpu_samples():
    """(busy_now, sample1, sample2) from `top -l 2`. -l 2 IS FORCED, NOT COSMETIC.

    The FIRST `CPU usage:` line is the average SINCE BOOT and therefore lies about NOW --
    measured 2026-10-10 on this box the two samples on one tick read 79.2% and 86.7% busy.
    A single-sample read reports the since-boot mean, which is the wrong question when the
    question is "can this box take another session right now".
    """
    out = _res_run(["top", "-l", "2", "-n", "0", "-s", "1"])
    if not out:
        return None, None, None
    rows = re.findall(r"CPU usage:\s*([\d.]+)% user,\s*([\d.]+)% sys,\s*([\d.]+)% idle", out)
    if len(rows) < 2:
        return None, None, None
    busy = [round(100.0 - float(t[2]), 1) for t in rows]
    return busy[-1], busy[0], busy[-1]


def _runnable_count():
    """Run-queue depth: processes in state R. THE predictor of whether a new lane starts now."""
    out = _res_run(["ps", "-Ao", "stat"])
    if out is None:
        return None
    return sum(1 for ln in out.splitlines()[1:] if ln.strip().startswith("R"))


def _mem_signals():
    """(used_pct, pressure_free_pct) -- TWO INDEPENDENT READINGS, DELIBERATELY BOTH.

    ⛔ THEY DISAGREE BY DESIGN, SO PRINT BOTH AND PICK NEITHER. MEASURED 2026-10-10 on this
    box: Apple's own `memory_pressure` said **58% free** while the page arithmetic said **7.6%
    free** on the SAME tick. One is a verdict, the other is arithmetic; collapsing them into a
    single number would hide whichever one the reader needed.
    """
    try:
        vs = _res_run(["vm_stat"])
        total = int(_res_run(["sysctl", "-n", "hw.memsize"]).strip())
        page = int(re.search(r"page size of (\d+) bytes", vs).group(1))
        free = int(re.search(r"Pages free:\s+(\d+)", vs).group(1))
        used = round(100.0 * (1.0 - (free * page) / total), 1)
    except Exception:
        used = None
    try:
        mp = _res_run(["memory_pressure"])
        free_pct = int(re.search(r"free percentage:\s*(\d+)%", mp).group(1))
    except Exception:
        free_pct = None
    return used, free_pct


def _swap_pct():
    """Swap used as a percentage of total. UNAMBIGUOUS: 90% used is an alarm, full stop."""
    try:
        out = _res_run(["sysctl", "-n", "vm.swapusage"])
        m = re.search(r"total = ([\d.]+)M\s+used = ([\d.]+)M", out)
        return round(100.0 * float(m.group(2)) / float(m.group(1)), 1)
    except Exception:
        return None


def _swap_activity(seconds=5):
    """Page-OUTS per second over a SHORT interval -- CURRENT pressure, not peak pressure.

    ⛔ IT IS PAGE-OUTS, NOT PAGE-INS -- MEASURED 2026-10-10 on this box: `pageins/s` ran
    456 / 572 / 661 across three consecutive samples while `pageouts/s` read 0 / 0 / 0. Page-ins
    are AMBIENT (the box reads its page cache constantly with no memory pressure at all), so
    banding on them would have created a brand-new PERMANENT LATCH in the opposite direction --
    the same defect, mirrored. Page-outs are writes TO swap, which only happen when memory
    pressure is forcing eviction, and they read ZERO when the box is healthy.

    ⛔ `sysctl vm.swapusage` REPORTS A HIGH-WATER MARK, AND BANDING ON IT LATCHES THE GATE SHUT.
    macOS does not proactively release swap, so `swap used` stays near its maximum indefinitely
    once the box has peaked. MEASURED 2026-10-10 across EIGHTEEN consecutive beats it drifted
    90.1 -> 86.8 -- 3.3 points -- while cpu moved 30 points and runq moved 74. So the old band
    held `DO: RECLAIM` on a box at `cpu=71.3% runq=5/10`, withholding three genuinely idle lanes
    from a 12-PR review backlog. A GATE THAT CAN NEVER OPEN IS NOT A GATE -- it trains the reader
    to ignore it, the same failure as the contradictory DO line fixed this morning, arriving
    through a threshold instead of a contradiction. Page-in RATE does fall when pressure lifts,
    so the rate is what gets banded and `swap used` becomes a REPORTED number only.
    """
    def pageins():
        try:
            return int(re.search(r"Pageouts:\s+(\d+)", _res_run(["vm_stat"])).group(1))
        except Exception:
            return None
    a = pageins()
    if a is None:
        return None
    time.sleep(seconds)
    b = pageins()
    if b is None:
        return None
    return max(0, int(round((b - a) / float(seconds))))


def _top_proc():
    """(name, pcpu) of the hottest process -- TURNS A THERMOMETER INTO A RUNAWAY DETECTOR.

    This is the field that surfaces a spun `admin-merge.sh` (agent-infra#1635), which is what
    actually happened on 2026-10-10 and which no aggregate percentage can show.
    """
    out = _res_run(["ps", "-Ao", "pcpu,comm", "-r"])
    if out is None:
        return None, None
    lines = [ln for ln in out.splitlines()[1:] if ln.strip()]
    if not lines:
        return None, None
    try:
        pcpu, comm = lines[0].strip().split(None, 1)
        return os.path.basename(comm.strip()), float(pcpu)
    except Exception:
        return None, None


# ⛔ THE BANDS ARE ACTIONS, NOT DIAGNOSES -- and the OLD `load <= 12` rule is NOT used.
# AGENTS.md said "load above ~12 on 10 CPUs makes sessions unreachable"; MEASURED 2026-10-10
# that is WRONG -- the box LANDED PRs at load 81 and ran productively at 25-40. Load is a
# LAGGING average (1/5/15 min) and cannot answer "right now"; the run queue can, so the band
# uses runq against cores and treats the averages as uninteresting.
#
# ⛔ MEMORY IS BANDED ON PRESSURE, NOT ON `mem used`. On macOS `Pages free` sits near zero
# because the OS uses spare RAM as cache, so `mem = 1 - free/total` is chronically 95-99% and is
# LATENTLY LATCHED for the same reason `swap used` is. MEASURED on the beat above: `mem=94.4%`
# while Apple's own verdict said **68% free** -- i.e. the arithmetic would have kept the gate
# shut on a healthy box even after the swap term was fixed. So `mem` is REPORTED and Apple's
# pressure verdict is BANDED (which is what the original spec meant by "the band uses Apple's
# own pressure verdict and swap").
RES_RECLAIM_CPU, RES_RECLAIM_PRESSURE_FREE, RES_RECLAIM_SWAPACT = 90, 10, 50
RES_HOLD_CPU, RES_ONE_CPU, RES_MANY_CPU, RES_MANY_SWAPACT = 75, 50, 50, 50
# Every band input. A missing one forces `UNKNOWN` rather than a confident band.
# `swap` is deliberately ABSENT from this tuple: it is printed, but it no longer decides.
RES_REQUIRED = ("cpu", "runq", "cores", "mem_used", "pressure_free", "swap_act",
                "top_name", "top_pcpu")


def res_action(r):
    """The DO for the resource line. RECLAIM first, then walk down. UNKNOWN is not a band.

    ⛔ AN UNREAD SIGNAL NEVER PRODUCES A CONFIDENT BAND. A partial read that still answered
    "dispatch-many" would be the same false-confidence defect as a false zero -- so ANY
    missing input returns UNKNOWN and the reader is told to look, not to dispatch.
    """
    if any(r.get(k) is None for k in RES_REQUIRED):
        return "UNKNOWN"
    if (r["cpu"] >= RES_RECLAIM_CPU or r["runq"] >= r["cores"]
            or r["swap_act"] >= RES_RECLAIM_SWAPACT
            or r["pressure_free"] <= RES_RECLAIM_PRESSURE_FREE):
        # Finding the runaway / retiring a lane IS the work; adding makes it strictly worse.
        # `swap used` is NOT here -- peak pressure must never force this.
        return "RECLAIM"
    if r["cpu"] >= RES_HOLD_CPU:
        return "hold"
    if r["cpu"] >= RES_ONE_CPU:
        return "dispatch-one"
    if r["runq"] < r["cores"] and r["swap_act"] < RES_MANY_SWAPACT:
        return "dispatch-many"
    return "hold"                  # cpu is low but the queue or swap activity is not: no green light


def resources():
    """The five `RES:` signals, each None when it could NOT be read (see res_action).

    ⛔ A SIGNAL THAT COULD NOT BE READ IS `None`, NEVER `0`. A prototype of this segment
    printed `pi processes=0` from a `pgrep` pattern that did not match -- a FALSE ZERO, the
    same defect class as the false all-clear this file has already been burned by. Zero is a
    claim; None is an admission, and the admission is what keeps the DO honest.
    """
    r = {}
    try:
        r["cores"] = os.cpu_count()
        r["phys"] = int(_res_run(["sysctl", "-n", "hw.physicalcpu"]).strip())
    except Exception:
        r["cores"] = r["phys"] = None
    r["cpu"], r["cpu_s1"], r["cpu_s2"] = _cpu_samples()
    r["runq"] = _runnable_count()
    r["mem_used"], r["pressure_free"] = _mem_signals()
    r["swap"] = _swap_pct()
    r["swap_act"] = _swap_activity()
    r["top_name"], r["top_pcpu"] = _top_proc()
    return r


def _rf(v, suffix=""):
    """Render a signal: `UNKNOWN` when it was not read, never a fabricated zero."""
    return "UNKNOWN" if v is None else f"{v}{suffix}"


def res_line(r=None, age=0):
    """The `RES:` line. EVERY field is load-bearing, so unlike the PR tokens NOTHING is omitted.

    `res_age` is not decoration: a resource reading has a validity of SECONDS, and this line does
    not merely report -- it AUTHORISES CONCURRENCY. A stale HIGH keeps saying RECLAIM after the
    box recovers (harmless); a stale LOW authorises a dispatch into a box that is now saturated,
    which is the exact failure this segment exists to prevent. So the age is ON the line, where a
    stale read is visible AS stale instead of being printed as current.
    """
    r = resources() if r is None else r
    top = "UNKNOWN" if (r.get("top_name") is None or r.get("top_pcpu") is None) \
        else f"{r['top_name']}({r['top_pcpu']}%)"
    return ("RES: cpu={}% runq={}/{} mem={}%|{}%free swap={}% swap-act={}pg/s top={} "
            "res_age={}s | DO: {}").format(
        _rf(r.get("cpu")), _rf(r.get("runq")), _rf(r.get("cores")),
        _rf(r.get("mem_used")), _rf(r.get("pressure_free")), _rf(r.get("swap")),
        _rf(r.get("swap_act")), top, age, res_action(r))


# Resource actions that must NEVER coexist with a dispatch instruction on the same line.
# `UNKNOWN` is included because "I cannot read the resources" must not authorise adding lanes.
GATE_ACTIONS = ("RECLAIM", "hold", "UNKNOWN")
DISPATCH_MARKER = "IDLE->"
DISPATCH_PHRASES = ("need dispatch", "hand the next unheld item")


def is_dispatch_clause(clause):
    """True iff the clause asks the reader to ADD a lane.

    ⛔ DETECTED STRUCTURALLY, NOT BY MATCHING ONE SENTENCE. The first version of this gate matched
    the literal `need dispatch`, so when the emitter switched to its SECOND shape --
    `IDLE->hand the next unheld item: ...` -- the gate silently stopped matching and FOUR lanes
    were offered for dispatch while `DO: RECLAIM` said add nothing. Every dispatch shape marks
    itself with `IDLE->`; keying on the MARKER rather than a phrase is what makes a NEW shape
    INHERIT the gate instead of bypassing it. A gate that a new emitter can evade by phrasing is
    not a gate, and this one evaded exactly that way.
    """
    c = clause or ""
    return DISPATCH_MARKER in c or any(p in c for p in DISPATCH_PHRASES)


def gate_dispatch(res_act, do_clause, reason):
    """ONE ACTION PER LINE: where two subsystems disagree, the MORE RESTRICTIVE wins and says why.

    ⛔ `RES: ... | DO: RECLAIM` BESIDE `DO: IDLE->2 need dispatch` GIVES THE READER TWO OPPOSITE
    IMPERATIVES AND NO WAY TO RECONCILE THEM -- worse than a missing line, because it costs a
    dispatch cycle and teaches the reader to ignore BOTH tokens (the #7957 H3 criterion: the
    instrument must agree with itself). So a resource verdict that says "add nothing" NEUTRALISES
    the dispatch verb instead of contradicting it, and attaches the reason.
    """
    if res_act in GATE_ACTIONS and is_dispatch_clause(do_clause):
        c = do_clause
        for phrase in DISPATCH_PHRASES:
            c = c.replace(phrase, "WITHHELD")
        return (f"[RES {res_act}] " + c.strip()
                + f" ({reason}): adding lanes makes it worse")
    return do_clause


def main():
    args = sys.argv[1:]
    # ⛔ THE GATE BELONGS AT THE POINT OF EMISSION, NOT INSIDE ONE CLAUSE'S FORMATTER. This mode
    # takes the ALREADY-COMPUTED `RES:` line (so there is no second measurement) and gates
    # whatever clause arrives on stdin -- so a NEW DO-line shape cannot be added without
    # inheriting the gate. The gate itself is structural: see `is_dispatch_clause`.
    if "--gate-clause" in args:
        _i = args.index("--gate-clause")
        _rl = args[_i + 1] if len(args) > _i + 1 else ""
        _m = re.search(r"\| DO: ([A-Za-z-]+)", _rl)
        _rq = re.search(r"runq=(\S+?) ", _rl)
        _sw = re.search(r"swap=(\S+?)%", _rl)
        print(gate_dispatch(_m.group(1) if _m else "UNKNOWN", sys.stdin.read().strip(),
                            f"runq={_rq.group(1) if _rq else '?'} "
                            f"swap={_sw.group(1) if _sw else '?'}%"))
        return
    # ⛔ `--res` COMPUTES FRESH AND NEVER TOUCHES THE CACHE. The resource line first shipped on
    # `objective.last` LINE 3, which inherits that file's 900 s TTL, and the beat then read line 3
    # back with `sed -n 3p` -- so two beats 7m33s apart printed BYTE-IDENTICAL values, including
    # `runq=79` and `top=OrbStack Helper(157.6%)`, which CANNOT repeat on a live box. A resource
    # reading is valid for SECONDS; it is also cheap (no network, no `gh`), so caching it buys
    # nothing -- the TTL exists to bound API cost, and this read has none.
    if "--res" in args:
        _r = resources()
        print(res_line(_r, age=0))
        if "--gate" in args:
            print(gate_dispatch(res_action(_r), sys.stdin.read().strip(),
                                f"runq={_rf(_r.get('runq'))}/{_rf(_r.get('cores'))} "
                                f"swap={_rf(_r.get('swap'))}%"))
        return
    max_age = 900
    if "--max-age" in args:
        try:
            max_age = int(args[args.index("--max-age") + 1])
        except Exception:
            pass
    if "--json" in args:
        max_age = 0

    # self-cache: the heartbeat calls this every tick; recompute at most once per window
    _serve_max = min(max_age, VERDICT_SERVE_MAX_S) if max_age else 0
    try:
        if _serve_max and os.path.exists(CACHE) and time.time() - os.path.getmtime(CACHE) < _serve_max:
            if "--json" not in args:
                # ⛔ SERVE THE *OBJECTIVE* LINE BY NAME, NOT THE LAST LINE. `RES:` is line 3, so
                # `[-1]` would serve the RESOURCE line where the verdict belongs.
                _cached = next((ln for ln in open(CACHE).read().splitlines()
                                if ln.startswith("OBJECTIVE")), None)
                if not _cached:
                    raise ValueError("no OBJECTIVE line in cache")
                # ⛔ LIVENESS CHECK AGAINST THE HEAD THE LINE DESCRIBES (2026-10-05).
                # The cache had NO liveness check, so a line describing one tree was served
                # for any later tree. Measured: the fleet brief printed ci_crit_max=36.7m(test (a))
                # while the true worst leg at that same head was 12.5m(test (g)) — a 3x-stale
                # number repeated into every brief, and it sent readers to a shard that was not
                # the slow one. A cache without a liveness check against its source is a liability
                # that reads as an asset. Recompute when the head has moved; on any doubt, recompute.
                _serve = False
                try:
                    _want = next((t[5:] for t in _cached.split() if t.startswith("main=")), None)
                    _cur = main_sha()
                    if _want and _cur:
                        _serve = (_want == _cur or _cur.startswith(_want)
                                  or _want.startswith(_cur))
                except Exception:
                    _serve = False          # cannot PROVE liveness → do not serve
                if _serve:
                    print(_cached)
                    return
    except Exception:
        pass

    try:
        line = build(_previous_sample())
    except Exception as e:                      # never break the heartbeat
        line = f"OBJECTIVE VERDICT=UNKNOWN error={str(e)[:60]}"
    # `RES:` GOES ON ITS OWN LINE. The objective line is already past the 150 chars
    # `cadence-nudge.sh` reads it with (`cut -c1-150`), so APPENDING this segment would push
    # `DO: fix-ci=` off the end -- which is how `fix-ci=` is being truncated today.
    try:
        res = res_line()
    except Exception as e:
        res = f"RES: UNKNOWN error={str(e)[:60]} | DO: UNKNOWN"
    # ⛔ A FAILED READ MUST NOT BE CACHED (2026-10-03).
    # The cache is mtime-keyed and holds ONE line, so it cannot tell a good read from a failed
    # one -- and a failure therefore inherits the FULL 900s window. MEASURED: at 16:59 a
    # transient GitHub 5xx (its own "No server is currently available", REST 4/5, GraphQL 5/5,
    # rate limits 5000/5000) wrote `main=UNKNOWN@? gh=UNREADABLE(queue) queue=UNREADABLE` into
    # this cache, and every heartbeat tick until 17:14:53 served it -- while a FORCED read at
    # 17:07 returned `ADVANCING main=GREEN@478c5e0e4`. One blip became a 15-MINUTE BLACKOUT.
    # The retry in _gh_retry absorbs the blip at source; this stops a surviving one from being
    # frozen. Both are the same rule this file's header already states in another form: an
    # empty read and an absent thing must never share a word -- and must never share a cache.
    blind = ("gh=UNREADABLE" in line or "main=UNKNOWN@?" in line or "error=" in line)
    try:
        if not blind:
            os.makedirs(STATE, exist_ok=True)
            with open(CACHE, "w") as f:
                f.write(datetime.now(timezone.utc).isoformat() + "\n" + line + "\n"
                        + res + "\n")
    except Exception:
        pass
    print(line)


if __name__ == "__main__":
    main()
