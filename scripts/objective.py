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
heartbeat can call it every tick CHEAPLY, never raise. "Cheap" is not "free" on
one path: a recompute that lands inside GitHub's lazy `mergeStateStatus` window
re-reads a few times before it will call the queue blind (#1869), which spends
up to `QUEUE_BLIND_BUDGET_S` of the beat's own 90 s refresh bound -- and a
refresh killed at that bound writes NO line at all. It reads; it does not act.
Nothing dispatches from here.

THREE MEASUREMENT TRAPS THIS SCRIPT EXISTS TO AVOID, all hit for real:
  1. A run's `createdAt -> updatedAt` INCLUDES QUEUE WAIT. It read 44.3 min and
     was reported as "CI is 44 minutes" -- the real execution median was 5.7 min
     and the true critical path was 11.6-17.3 min. CI time here is JOB wall time.
  2. Per-attempt check-runs: one sha carries many attempts of a job, and a
     re-run ADDS an attempt without clearing one. Group by (app, workflow, job)
     and take the NEWEST BY `id`, then judge by POLARITY -- anything not in the
     green/non-red sets is RED, including conclusions GitHub has not documented.
     A missing check is NOT a green check.
  3. A LAZILY-COMPUTED answer is not a failed read -- it is a read taken too
     early. `mergeStateStatus` reads UNKNOWN for the WHOLE queue while GitHub
     recomputes it, with no error anywhere, so ONE sample can be blind on a
     perfectly healthy API: the queue read is re-sampled before blindness is
     declared, and a queue that never settles is still reported BLIND (#1869).

Usage:  objective.py [--json] [--max-age 240]
Output: OBJECTIVE VERDICT=... prs_waiting=N ... main=RED|GREEN|UNKNOWN@sha ...
"""
from __future__ import annotations
import json, os, re, subprocess, sys, time
from collections import Counter, defaultdict
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
# ⛔ THE BUCKET IS DERIVED FROM THE LIVE CLAIMS, NEVER LEFT OVER FROM A WITHDRAWN ONE (#2138 r2).
# `GH_BLOCKED` used to be a single mutable word set by whichever read failed LAST, so a claim that
# was later WITHDRAWN could survive as the kind of a DIFFERENT surface: main reading `HTTP 504`
# (UNREADABLE) plus a queue refusal that REST then recovered (RATE-LIMITED, retracted) left
# `GH_BLOCKED='RATE-LIMITED'` against main -- the line printed `gh=RATE-LIMITED(main)` and rewrote
# the verdict to "wait for the limit" on a tick whose real story was "main's read 504'd; the queue
# read FINE". That is the same misattribution class `_note_gh_failure`'s docstring already records
# ("the token named the wrong subsystem"), one level down. One kind + text per surface, and the
# bucket is recomputed on every note and every withdrawal.
GH_CLAIM_KIND = {}
GH_CLAIM_TEXT = {}

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
#
# ⛔ `transport` IS TRI-STATE, AND THAT IS WHAT MAKES A STATEMENT AUTHORITATIVE (#2138 r9, BOTH
# reviewers). It was a bool whose `True` was only NECESSARY, never SUFFICIENT: the gate in
# `_note_gh_failure` still demanded one of `TRANSPORT_MARKERS` in the text, so a caller that
# correctly stated "this was a transport failure" was overruled by a SPELLING TEST. Measured on a
# REAL `urllib` refusal — `str` of an `HTTPError` is "HTTP Error 403: Forbidden", which contains no
# marker, because "http 4" is not a substring of "http error 403" — so a mangled primary plus a
# genuine 403 still published `queue=UNREADABLE` with no `gh=` and `VERDICT=UNKNOWN`: the round-7 OR
# was INERT for exactly the input it was written for. The old test masked it by inventing an
# `OSError("HTTP Error 403: API rate limit exceeded …")`, a string this code path cannot produce.
# So:
#     transport=True   the caller STATES it could not reach GitHub   -> claims
#     transport=False  the caller STATES GitHub answered             -> no claim
#     transport=None   the caller holds NO per-read fact             -> the text heuristic decides
# `queue()` always passes a stated bool (`primary_transport` / `_REST_TRANSPORT`), and `_rest_get`
# names a refusal by its real STATUS so the KIND (RATE-LIMITED vs UNREADABLE) follows evidence.
# `main_health()` is the ONLY `None` caller: `GH_LAST_ERROR` is SHARED module state that either
# `gh()`'s body-parse arm (`unparseable gh api body: …`) or `gql_commit_checks()`'s rollup arm can
# have written, so main has no per-read fact to pass and the heuristic still decides for it. Filed
# as #2151 rather than fixed here: attributing main's cause per READ is a main-path refactor.
TRANSPORT_MARKERS = ("rate limit", "http 5", "http 4", "timed out", "timeout",
                     "could not resolve", "connection", "network", "tls", "ssl",
                     "temporary failure", "gateway", "unable to access")


def _recompute_gh_blocked():
    """The bucket for the claims that are still LIVE (see GH_CLAIM_KIND).

    RATE-LIMITED outranks UNREADABLE because it is the more actionable answer (wait vs debug),
    which is the precedence the single-word version already had -- kept, not reinvented.
    """
    kinds = [GH_CLAIM_KIND.get(s, "UNREADABLE") for s in GH_BLOCKED_BY]
    if not kinds:
        return None
    return "RATE-LIMITED" if "RATE-LIMITED" in kinds else "UNREADABLE"


def _note_gh_failure(text, surface, transport=None):
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

    `transport` is TRI-STATE (see the note above `TRANSPORT_MARKERS`): `True`/`False` is a fact the
    caller OWNS and is honoured as given; `None` means the caller has no per-read fact and the text
    heuristic decides. Only the `None` form consults `TRANSPORT_MARKERS` (#2138 r9).
    """
    global GH_BLOCKED, GH_LAST_ERROR
    GH_LAST_ERROR = text or ""
    if surface not in BLINDING_SURFACES:
        return                     # an optional read: it degrades a number, not the verdict
    low = (text or "").lower()
    if transport is False:
        return                     # the caller STATES GitHub answered: not blindness
    if transport is None and not any(m in low for m in TRANSPORT_MARKERS):
        return                     # no per-read fact to honour: guess from the text (#2151)
    if surface not in GH_BLOCKED_BY:
        GH_BLOCKED_BY.append(surface)
    if "rate limit" in low:
        GH_CLAIM_KIND[surface] = "RATE-LIMITED"
    else:
        GH_CLAIM_KIND.setdefault(surface, "UNREADABLE")
    GH_CLAIM_TEXT[surface] = text or ""
    GH_BLOCKED = _recompute_gh_blocked()


GH_LAST_ERROR = ""
# Whether the LAST `_queue_rest()` failure was a TRANSPORT failure (the exchange with GitHub did
# not complete) rather than a body/config failure. Read by `queue()` to classify the composite
# refusal (#2138 r7). NOTE `_rest_get` DECODES its own body, so it also raises for a 200 it could
# not parse -- that is a body failure, and the classification below says so (#2138 r8).
_REST_TRANSPORT = False

# ⛔ THE BINARY IS RESOLVED, NOT TAKEN FROM PATH ALONE (#1872, reviewer E). `pr-doctor.py`
# records the incident at its own `GH` constant: on the fleet box `~/.pi/agent/shims/gh` is a
# symlink into ~/Documents, macOS TCC refuses to execute it (rc=126) under launchd, and the job
# then printed a plausible "no open PRs" for two straight runs while doing NOTHING. That
# protection used to hold only for pr-doctor's OWN reads; since pr-doctor's read was DELETED in
# favour of this one (#1872), this file performs the load-bearing read, so the resolution must
# hold here too. ~/bin/gh is a real binary outside the protected
# tree; a box without it (CI, Linux) falls back to PATH, which is what it has always effectively
# used there.
# ⛔ `isfile` AND `access` — `os.access(p, os.X_OK)` is TRUE FOR A DIRECTORY, so the executable
# test alone would adopt `~/bin/gh` even if it were a directory and then raise PermissionError on
# the first read (reviewer E, #1872 review round 2). The remaining residual is honest: a stale
# `~/bin/gh` that exists and runs but predates a flag this file uses (`--slurp`) would still win
# over PATH. It is recorded here rather than probed, because a capability probe costs a
# subprocess per process start for a case no reader of this file has ever been the cause of.
#
# ⛔ AND PREFER THE HARNESS'S OWN gh LAYER (#1988) WHEN ONE IS DEPLOYED. `objective.py` is the
# highest-volume READ on the shared account (the heartbeat's refresh), so resolving straight at the
# real binary made the layer inert for the caller that spends the most quota. The layer's path comes
# from `$O` — NEVER from PATH. ⛔ THE LAYER ITSELF then resolves the real gh by walking PATH, so
# "#1872 cannot come back" would be FALSE: in a minimal environment the first `gh` on PATH can be a
# shim that refuses at runtime (the 2026 incident: rc=126 with `os.access` still passing). The pin
# is therefore passed THROUGH the layer (`GH_REST_REAL_GH`/`GH_LIMIT_REAL_GH`), so these readers keep
# calling the binary #1872 chose for them and still get serialisation and backoff.
def _gh_layer():
    o = os.environ.get("O", "")
    if not o:
        return None
    # ⛔ ORDER: `gh-rest` FIRST, matching every shell call site (`orch-loop.sh`: "adapter last so
    # `$O/gh-rest` wins where it exists"). The adapter serves a GraphQL refusal over REST (#1959);
    # preferring the non-translating wrapper here made this reader fail exactly as it did before that
    # fix while the same box's shell calls took the other transport.
    for c in (os.path.join(o, "gh-rest", "gh"), os.path.join(o, "gh-limit", "gh")):
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


GH_REAL_PIN = next((p for p in (os.path.expanduser("~/bin/gh"),)
                     if os.path.isfile(p) and os.access(p, os.X_OK)), None)
GH_BIN = (os.environ.get("OBJECTIVE_GH")
          or _gh_layer()
          or GH_REAL_PIN
          or "gh")
# The layer resolves the real gh itself; tell it WHICH one (see _gh_layer's comment). Empty when we
# are not going through a layer, so a direct call is unaffected.
GH_LAYER_ENV = ({"GH_REST_REAL_GH": GH_REAL_PIN, "GH_LIMIT_REAL_GH": GH_REAL_PIN}
                if GH_REAL_PIN and GH_BIN.endswith(("/gh-rest/gh", "/gh-limit/gh")) else {})


# ⛔ THE LAYER MUST NOT SLEEP INSIDE THIS PROCESS (#1988). The heartbeat bounds this refresh (90/120 s)
# while the layer's first documented backoff is 60 s: an in-call wait outlives the caller, and the
# caller is killed before the layer can say why — a rate-limited box then reports UNKNOWN/STALL
# instead of the RATE-LIMITED verdict it can prove. NO_WAIT makes the layer record the limit and
# return at once, so this process's own deferral takes over. It is inherited by every DESCENDANT
# of this process — all of them parts of the same bounded heartbeat step.
os.environ.setdefault("GH_LIMIT_NO_WAIT", "1")


def gh(*args, paginate=False):
    """A REST read. Records WHY it failed, but never declares the fleet blind by itself.

    Only reads the objective actually depends on -- main's state, and the queue -- are
    allowed to do that, via `_note_gh_failure`. Measured 2026-09-29: the optional CI-duration
    sample kept re-setting the flag AFTER main had been read successfully over GraphQL, so a
    degraded metric read as a total blackout and the verdict stayed GH-BLOCKED while main's
    red was fully visible.
    """
    global GH_LAST_ERROR
    cmd = [GH_BIN, "api"] + (["--paginate", "--slurp"] if paginate else []) + list(args)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=90,
                       env={**os.environ, **GH_LAYER_ENV} if GH_LAYER_ENV else None)
    if r.returncode != 0:
        GH_LAST_ERROR = (r.stdout or "") + (r.stderr or "")
        return None
    try:
        d = json.loads(r.stdout)
    except Exception:
        # ⛔ A BODY WE CANNOT PARSE IS A FAILURE WITH A CAUSE (#1872 review round 2): returning a
        # bare None here left `GH_LAST_ERROR` at its previous value, so the dispatcher's new
        # "why were the checks unreadable" line printed "(no gh error recorded)" -- or, worse,
        # a PREVIOUS read's error, naming the wrong cause for the right symptom.
        GH_LAST_ERROR = "unparseable gh api body: " + (r.stdout or "")[:200]
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
    r = subprocess.run([GH_BIN, "api", "graphql", "-f", f"query={q}",
                        "-f", "owner=daniel-ospina", "-f", "name=tortoise"],
                       capture_output=True, text=True, timeout=90,
                       env={**os.environ, **GH_LAYER_ENV} if GH_LAYER_ENV else None)
    global GH_LAST_ERROR
    # ⛔ APPEND, NEVER REPLACE: this fallback runs BECAUSE the REST read already failed, and the
    # REST cause is the actionable one ("rate limit exceeded" says wait; a 404 on the fallback
    # says debug the fallback). Replacing it left only the second transport's error in the
    # dispatcher's cause line (#1872 review round 4).
    _prev = (GH_LAST_ERROR + " | ") if GH_LAST_ERROR else ""
    if r.returncode != 0:
        GH_LAST_ERROR = _prev + "graphql fallback rc=%s %s" % (r.returncode, (r.stderr or "")[:180])
        return None
    try:
        nodes = (json.loads(r.stdout)["data"]["repository"]["object"]
                 ["statusCheckRollup"]["contexts"]["nodes"])
    except Exception:
        GH_LAST_ERROR = _prev + "graphql fallback returned no rollup: " + (r.stdout or "")[:180]
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
        # ⛔ ONE IMPLEMENTATION, NOT A COPY (#2138 r2): the inline version removed the surface but
        # not its KIND, so main recovering could leave `GH_BLOCKED` naming a bucket no live claim
        # supported. `_withdraw_gh_failure()` recomputes it from the claims that remain.
        _withdraw_gh_failure("main")
    else:
        cr = gh(f"repos/{REPO}/commits/{sha}/check-runs?per_page=100&filter=all", paginate=True)
    if cr is None:
        # ⛔ `transport=None` IS DELIBERATE, NOT AN OMISSION (#2138 r9). `cr` is None on BOTH a
        # transport failure and an unparseable body, and the two write the SAME `GH_LAST_ERROR`
        # from two different arms — so there is no per-read fact to state here. The heuristic
        # decides, which is the pre-existing false-blindness #2151 tracks.
        _note_gh_failure(GH_LAST_ERROR, "main", transport=None)
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


def _sleep(seconds):
    """Sleep, behind ONE indirection, so the blind-resample backoff is provable in a test
    without spending the wall clock (and without brushing CI's per-test `--timeout`, #1869).

    ⚠️ This DELIBERATELY departs from the repo's other suites, which patch the module's own
    `time` (`test_lane_watchdog.py`, `test_lane_status.py`: `setattr(mod.time, "sleep", ...)`).
    `objective.time` IS the stdlib module object, so that convention patches it PROCESS-WIDE for
    the duration of the test; this module is also copied into `~/.pi/agent/scripts` and run by a
    live loop, so its wait is worth one explicit, local seam instead.
    """
    time.sleep(seconds)


def _monotonic():
    """Monotonic seconds, behind ONE indirection, so the re-sample DEADLINE is testable too.

    An attempt count alone does not bound a re-sample loop: the READ can be slow (a full
    recompute costs ~12 s measured, and one hung `gh` costs up to its own 120 s timeout), so a
    fixed ladder of sleeps on top of a slow read is bounded by nothing the beat can honour
    (`run_bounded 90`). The loop therefore checks a wall-clock deadline as well -- and a
    deadline is only honest if it can be tested without waiting for it.
    """
    return time.monotonic()


def _gh_retry(argv, attempts=3, timeout=120, deadline=None):
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
        # ⛔ `deadline` BOUNDS THE WHOLE RETRY POLICY, NOT JUST ONE ATTEMPT (#2138 r4, A). The
        # queue read's cap covers the read the fleet depends on -- but a retrying 5xx could spend
        # `attempts x timeout` (3 x 120 s) and be killed by `run_bounded 90`, writing NO line at
        # all. With a deadline, each attempt's timeout is clipped to what is left of it and the
        # backoff sleep is clipped too, so retries still happen (the resilience this function
        # exists for) inside a bound the caller can price into the tick.
        tmo = timeout
        if deadline is not None:
            left = deadline - _monotonic()
            if left < 1.0:
                if last is not None:
                    return last
                raise TimeoutError("gh read: the read's budget was spent before the call")
            tmo = min(timeout, left)
        last = subprocess.run(argv, capture_output=True, text=True, timeout=tmo,
                              env={**os.environ, **GH_LAYER_ENV} if GH_LAYER_ENV else None)
        if last.returncode == 0:
            return last
        low = ((last.stdout or "") + (last.stderr or "")).lower()
        transient = any(m in low for m in (
            "no server is currently available", "gateway timeout", "http 5", "server error",
            "timed out", "timeout", "503", "504", "try again", "temporarily unavailable"))
        if not transient or i == attempts - 1:
            return last
        # The backoff is clipped AT SLEEP TIME, not before the attempt: the attempt itself just
        # spent real time, so a nap priced from the pre-call clock could overrun the budget.
        nap = 2 * (i + 1)
        if deadline is not None:
            nap = min(nap, max(0.0, deadline - _monotonic()))
        _sleep(nap)
    return last


SURFACE_PATHS = ("tortoise/sdk.py", "tortoise/tool_registry.py",
                 "config/surface-manifest.yml")
# The owner-designed class vocabulary (2026-10-10): the ACTION classes in
# cheapest-and-highest-payoff FIRST, plus `running`, which is a first-match STATE and never an
# action. Reading this tuple as a class->action map is what sent lanes to "fix" a suite that was
# still executing (#1872); every consumer must special-case `running` (both do: pr-doctor skips
# it, pr-loop returns `wait`).
# `call-rail` first: it is the win -- the SIX gated required checks green AND a clean
# attestation at the current head, i.e. the merge rail's own script lands it with zero code work.
# ⛔ NOT "all 7": `ai-review-gate` is diff-bound, red by construction whenever a record postdates
# its last run (measured red on 8 of 11 open PRs), and its truth is the attestation FILE -- so it
# is never a check this predicate waits on.
# `rerun-checks` and `resolve-conflict` sit ABOVE `record-review` because a missing check
# tells you NOTHING and a rebase CHANGES THE HEAD, staling any attestation.
CLASS_ORDER = ("call-rail", "blocked-by-rail", "rerun-checks", "resolve-conflict",
               "record-review", "running", "fix-ci")
# ⛔ `running` IS A CLASS, NOT A GAP (#1872). A required check that is still IN FLIGHT is not
# work: the PR needs nothing but time. It has its own class because the alternative -- folding
# it into `fix-ci`, which this file did until 2026-10-16 -- told the fleet to go FIX a suite
# that was still executing. MEASURED live: #8825's `pricing-artifact` was mid-run, and the DO
# list named it as fix work.
#
# ⛔ AND THERE IS EXACTLY ONE CLASSIFIER. `pr-doctor.py`, the dispatcher, reads THIS file's
# `classify_one()`; it used to carry a second predicate under its own names (ready / failing /
# unreviewed / no-checks / running), sharing no code. MEASURED 2026-10-16 over the 11 live
# non-draft PRs: the two DISAGREED ON 4 (36%) -- #8825 (`fix-ci` vs `running`), and #8806 /
# #8822 / #8824 (`fix-ci` vs `unreviewed`). Same queue, same question, two answers. The beat
# may report the counts and the dispatcher acts on them, but they must come from one predicate.
# ⛔ RAIL_GATES MUST TRACK `scripts/admin-merge.sh` -- AND `call-rail` MEANS "THE RAIL WILL
# ACCEPT IT", NOTHING WEAKER. The rail refuses on MORE than the 7 branch-protection contexts.
# MEASURED 2026-10-10: `call-rail=1: #7924 (STUCK 3 beats)` sent a lane to call a rail that
# REFUSED #7924 for flip-gate/drift-guard -- three hours of `call-rail` on the line with NOTHING
# landable behind it, which is how a fleet learns to distrust the token. The note that
# `drive`/`drift-guard`/`sigpipe-guard` are "never blockers" is TRUE for the 7 required contexts
# and FALSE for the rail; the instrument inherited the wrong one.
RAIL_GATES = ("flip-gate", "drift-guard", "provenance")
# ⛔ EXCLUDED FROM THE DO LIST BECAUSE IT IS NOT REQUIRED -- NOT BECAUSE IT "CANNOT PASS".
# MEASURED 2026-10-11, job 114560749590: `agent-infra-ci / lint` is an ordinary ruff gate
# (`tortoise/.github/workflows/ci.yml:2023` -> `lint-command: pip install ruff==0.16.4 && ruff check .`).
# It issues NO merge command, has NO review-enforcement guard, and refuses nothing. It failed with
#     "Found 6 errors. [*] 3 fixable with the `--fix` option"
# -- six REAL lint errors, three auto-fixable, owned by #5203. So this red is GENUINE WORK, just not
# the work of any PR lane: it is main-side (ruff lints the whole tree, so every .py-changing PR
# inherits it) and the check is not one of the 7 required contexts.
#
# ⚠️ THE "CANNOT PASS BY CONSTRUCTION" STORY IS REAL -- BUT IT IS A DIFFERENT ARTIFACT. The guard that
# prints "✅ Review enforcement (admin-merge evidence) gate is working correctly." and then refuses the
# very rail it mandates (so the guard succeeding IS the job failure) is `extensions/review-enforcer` /
# `extensions/ln` in agent-infra, exercised by `agent-infra/.github/workflows/ci-main.yml:144-150`.
# That is tortoise #6395 / agent-infra #1203 -- both OPEN. Do NOT attach that mechanism to THIS name:
# it would hide six fixable lint errors behind a "nothing to do here" story, which is the failure this rail exists to
# prevent. Two different checks; one name was doing duty for both.
NOT_REQUIRED_CHECKS = ("agent-infra-ci / lint",)


# ⛔ A TOKEN THAT NAMES AN ACTION BUT NOT ITS OBJECT IS A REPORT, NOT AN INSTRUCTION.
# A lane reading `call-rail=3` had to RE-DERIVE WHICH THREE -- re-run the check rollup, re-read
# the attestation files, and decide -- which is the exact work the instrument exists to remove.
# So these classes name their PRs. `fix-ci` deliberately does NOT (it is often 6+ PRs and would
# swamp the line with the one class that needs no triage to act on).
NAMED_CLASSES = ("call-rail", "blocked-by-rail", "record-review", "resolve-conflict",
                 "rerun-checks", "running")
# ⛔ `running` IS NAMED TOO (#1872). It is the one class whose action is "wait", and a check-run
# can stay non-`completed` indefinitely (a `queued` job starved of runners is MEASURED behaviour
# in this fleet). A bare `running=2` names no object, so a wedged PR would be invisible to every
# reader. Since #1926 a wedge PAST `FLIGHT_BOUND_MIN` reads `rerun-checks` instead -- but the
# window BELOW the bound is exactly where naming matters, because that is the state in which an
# operator has no other way to tell "a slow shard" from "the thing that is about to be stuck".
# The bound does not replace the names; it is what stops the naming from being the ONLY signal.
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
    """`call-rail=3: #7960 #7924 #7920 (STUCK 3 beats — pr-doctor has not landed it)`.

    The count is the priority signal and the numbers are the WORK. Escalation uses the
    longest-waiting PR, so one old stuck PR alarms even beside a freshly-arrived one.

    ⛔ THE ESCALATION STATES A FACT; IT DOES NOT GIVE AN ORDER (#1872). It used to end
    "— land or say why", which is an instruction to whoever reads the beat -- and the work it
    named was already `pr-doctor`'s, so the line was a second copy of a decision the chain was
    executing. What a MONITOR can add is the thing the dispatcher cannot see: that a landable PR
    has been landable for N beats and the chain has still not landed it. That is a state, and it
    is the alarm worth waking a human for.
    """
    tok = f"{name}={count}"
    if prs and name in NAMED_CLASSES:
        tok += ": " + " ".join(f"#{n}" + (f"({w})" if w else "") for n, w in prs)
    if name == "call-rail" and prs and stuck:
        n = max(stuck.get(str(p), 0) for p, _w in prs)
        if n >= 2:
            tok += f" (STUCK {n} beats — pr-doctor has not landed it)"
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
    global GH_LAST_ERROR
    GH_LAST_ERROR = ""          # the cause this pass reports must belong to THIS read
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


def newest_attempts(cr):
    """[(name, NEWEST attempt)] grouped by (app, workflow, job name), newest by `id`.

    A re-run ADDS a check-run; it does not clear one -- so the newest attempt by `id` is the
    only honest read. Grouping by (app, workflow, job name) keeps two workflows that share a
    job name apart, and `id` (not `started_at`, which is nullable) breaks the tie. ONE grouping
    for the whole file: a RED/FLIGHT verdict and an AGE verdict about the same job must be
    verdicts about the SAME attempt.
    """
    groups = defaultdict(list)
    for c in cr:
        app = (c.get("app") or {}).get("slug") or "?"
        du = c.get("details_url") or ""
        wf = "run" + du.split("/actions/runs/")[1].split("/")[0] if "/actions/runs/" in du else "?"
        groups[(app, wf, c.get("name"))].append(c)
    return [(name, max(items, key=lambda x: x.get("id") or 0))
            for (_a, _w, name), items in groups.items()]


def rollup_checks(cr):
    """(red, flight) name-sets by POLARITY on the NEWEST attempt per (app, workflow, name).

    Every conclusion that is neither green nor explicitly non-red is RED -- INCLUDING one
    GitHub has not documented, and a NULL one: read the group by polarity, never by an
    allow-list of the failures you happen to expect.
    """
    red, flight = set(), set()
    for name, newest in newest_attempts(cr):
        st = (newest.get("status") or "").lower()
        concl = (newest.get("conclusion") or "").lower()
        if st and st != "completed":
            flight.add(name)
        elif concl in GREEN or concl in NON_RED:
            continue
        else:
            red.add(name)
    return red, flight


# ⛔ A CHECK-RUN THAT NEVER COMPLETES IS NOT "IN FLIGHT" FOREVER (#1926). GitHub does NOT
# reconcile a run that was never picked up: a cancelled workflow, a runner that never came up,
# or a job created and then orphaned leaves `status != completed` at that head PERMANENTLY, and
# the classifier's answer is then indistinguishable from a healthy run's -- for as long as the
# PR stays open. Nothing else in this loop looks at a check's AGE.
#
# THE DEFECT IS A WAIT THAT NEVER ENDS. Pre-#1872 this shape fell to the last arm and read
# `fix-ci`, i.e. the beat told the fleet to go REPAIR CODE for a job that never ran (measured on
# this branch's base at main=57edbd7a0: `{'fix-ci': 1}`). With #1872 landed (#1930) the same shape
# is worse in the way that matters: `rollup_checks` puts ANY non-`completed` status in `flight`,
# so arm 5 answers `running` -- "the head is still executing" -- and both readers SKIP the PR and
# wait for a completion that will never arrive. #1930 said so as it landed: "#1926 (`running` has
# no age bound, so a wedged check-run parks a PR forever)". The re-trigger arms cannot reach it
# either: a wedged run IS a required context that REPORTED (so `req_seen` is non-empty, and the
# `gated_absent` arm 7 sees it as present) while never reaching `completed` -- so every
# absence-based arm is structurally blind to it, and only an AGE can tell it from a healthy run.
#
# THE BOUND, and what it is derived from. Two clocks have to be covered, because the age of a
# non-completed check is measured from whichever applies (see `flight_age_min`): a STARTED run's
# job wall time, and a NEVER-started run's wait, which includes the runner queue. This file's
# own measured figures, under the 2026-09 fleet load: the true execution critical path is
# 11.6-17.3m (docstring trap 1; the printed `ci_crit_max` has since read up to 18.1m), and the
# queue-INCLUSIVE run wall time (`createdAt -> updatedAt`) read 44.3m. The bound must sit above
# the queue-inclusive figure, so 90m is ~2x it -- comfortably clear of the worst documented
# HEALTHY wait, and still fast enough that a wedge is reported within ~1.5h rather than never.
# ⛔ NOT `ci_critical_path()`'s 36.7m: that value is the #7516 MEASUREMENT ARTIFACT (an 8-day
# window), and the function can no longer return it -- see the comment on CRIT_MAX_AGE_H.
# A CONSTANT, not a live read, on purpose: the classification stays pure, and an unmeasurable
# CI cannot silently switch the bound off.
# ⛔ RECORDED CONSEQUENCE (review note, no action): a head that is STARVED IN THE QUEUE rather
# than wedged also reads `rerun-checks` past the bound, and a re-trigger resets its age for
# another 90m -- so a starved head can cycle re-trigger -> starve -> re-trigger. That follows
# from the derivation above (90m ~ 2x the 44.3m queue-INCLUSIVE measurement) and is accepted:
# it is cheaper than the unbounded wait it replaces. If queue depth ever exceeds the bound, no
# bound alone can tell "starved" from "wedged" -- that would need the QUEUE POSITION, not an age.
# ⛔ AND IT IS NOT A CONTRADICTION OF `ci-failure-set.sh`'s "NO AGE BOUND, DECIDED DELIBERATELY".
# That decision is about a different artifact and a different question: a workflow RUN that
# GitHub never expanded (`jobs == 0`), i.e. there is NO check-run to age, judged by which runs
# count as `pending` before a landing. Here a check-run EXISTS at the head and is
# non-completed, and the question is what the BEAT should call it. Its reasons (the safe net is
# a `tested > 0` precondition; the only reachable clock would re-shape a shared run listing) do
# not reach this read, which carries its own clocks.
#
# ⛔ SCOPE, STATED -- AND THE TWO SHAPES ARE NOT THE SAME SHAPE (#1948 review cycle 4, P3).
# The aged set is the REQUIRED contexts (`GATED_CHECKS`). A wedged RAIL gate
# (`drift-guard`/`flip-gate`/`provenance`) is not in it, and it is never a `blocked-by-rail`
# REPAIR: `rail_block_reason` ACCEPTS an in-flight gate, but arm 1 returns `blocked-by-rail` only
# when that gate is in `red` (`if _rail in red`), so a wedged rail gate is non-`completed`, never
# `red`. That is DELIBERATE, one block above (#1872 review round 7: "an in-flight rail gate reads
# `running` and a RED one still reads `blocked-by-rail`") -- an in-flight gate is not work to
# repair. WHAT THEN HAPPENS DEPENDS ON WHETHER A REQUIRED GATE IS PRESENT:
#   * EVERY gated context present: `rail_block_reason` names the wedged gate, arm 1 falls through
#     to `running`, and the head WAITS -- unbounded, which is the one wait this change does not
#     bound. Ageing it there would change the ladder for a non-required surface, and that is a
#     separate call, deliberately not made here.
#   * a REQUIRED gate ABSENT: `wedge_evidence`'s all-contexts read (below) ages EVERY context, so
#     the rail gate can be the ONLY name in the reason -- `«drift-guard» queued <age>m` -- and the
#     head reads `rerun-checks` even when it is DIRTY. Measured through `classify_one` with the
#     suite's own fixture (review cycle 4): required gate absent + `drift-guard` queued PAST the
#     bound -> `rerun-checks` with `why` naming only `drift-guard`; the same head with
#     `drift-guard` FRESH -> `running`; and with the gated set complete and ATTESTED -> `running`
#     (the unbounded wait above). So the ladder DOES depend on a non-required surface's age in the
#     absence shape -- correct, because re-triggering a wedged run IS the repair and the gate has
#     to be STARTED before any question about it can be answered.
#
# ⛔ THE ONE OTHER USE OF AN AGE, AND WHY IT IS NOT THAT CALL (#1926 review, P1):
# `wedge_evidence` also ages EVERY context, but only to answer a narrower question -- *can the
# ABSENT required gate ever be created?* `python-ci-gate` is created only after its matrix
# children finish, so when a required gate is absent AND every check in flight is past the bound,
# nothing can create it and the `gated_absent and flight` term of `running` would wait for ever.
# A rail gate appears in THAT read only as one of the stuck jobs to START -- it is named as work to
# do, never as a `blocked-by-rail` repair -- and arm 1 still answers first on a fully-green gated
# set, where nothing is named as an order at all.
FLIGHT_BOUND_MIN = 90.0

# The contexts a landing actually waits on. `ai-review-gate` is EXCLUDED for the same reason
# `call-rail` excludes it: it is DIFF-BOUND, so its truth is the head-bound attestation FILE,
# never its check-run -- and re-triggering it does not make an attestation appear.
GATED_CHECKS = tuple(n for n in REQUIRED if n != "ai-review-gate")

# The contexts whose check-run is NOT their truth. `ai-review-gate` is DIFF-BOUND: it is red by
# construction whenever the head-bound attestation is older than the head, and a re-trigger cannot
# make an attestation appear. So it must never be NAMED as the thing to re-trigger either -- the
# name in the reason becomes the ORDER the lane is dispatched on (pr-doctor's brief renders
# "Re-trigger the workflow run behind `<why>`"), and naming this one sends a lane at a gate that a
# re-run provably cannot start. Excluding it from the WAIT (GATED_CHECKS, above) and from the
# REPORT (`DIFF_BOUND_CHECKS`, here) are the same ruling on the same fact (#1926 review, P1).
DIFF_BOUND_CHECKS = ("ai-review-gate",)


def _epoch_ts(v):
    """Unix seconds for a GitHub ISO-8601 timestamp, or None -- never a silent 0."""
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def _run_id(details_url):
    """The ACTIONS RUN id in a check-run's `details_url`, or None (a non-Actions app's run).

    ⛔ DIGITS OR NOTHING (#1926 review). The segment is interpolated into an authenticated
    `gh api repos/<org>/<repo>/actions/runs/<id>` PATH, i.e. into a request the CHECK-RUN AUTHOR
    controls the tail of: `..` normalises onto a DIFFERENT endpoint, and any other crafted
    segment spends a GET on the fleet's shared, rate-limited token. A real run id is always all
    digits, so anything else is not a clock -- None, which `flight_age_min` already treats as an
    unreadable age (the run stays in flight and no re-trigger is manufactured).
    """
    parts = (details_url or "").split("/actions/runs/")
    if len(parts) < 2:
        return None
    seg = parts[1].split("/")[0]
    return seg if seg.isdigit() else None


def _pass_run_clock():
    """`run_clock(run_id) -> unix seconds the run's CURRENT ATTEMPT started`, memoised.

    ONE clock object per `classify_one()` call, so every check-run in ONE PR is aged against the
    same reads -- and a PR is classified once per pass, so this is also the pass boundary.

    ⛔ THE CHECK SUITE'S `created_at` IS NOT THIS CLOCK, and using it was a real bug caught in
    review of the first cut of this fix. A re-run REUSES the suite: MEASURED 2026-10-17 on
    agent-infra run 39004542024 -- attempts 1 and 2 both carry check suite 105706798511, while
    `run_started_at` advanced 04:58:24 -> 05:05:10 (and the attempt-2 job's `created_at` is
    05:05:11, i.e. only the RUN/JOB attempt clocks advance). With the suite clock, a PR whose
    wedge was just re-triggered still aged from the original `created_at`, so the very next
    beat would call it wedged again and re-trigger it again -- the churn the bound exists to
    stop. `run_started_at` advances per attempt, so a re-trigger RESETS the age, as it must.

    Only the never-started shape spends a read here: a check-run that has started carries its
    own per-attempt `started_at` (also fresh after a re-run), and this closure is injected into
    `stalled_flight` so the age logic itself stays pure. An unreadable clock is None -- the run
    stays IN FLIGHT and never manufactures a re-trigger.
    """
    memo = {}

    def run_clock(run_id):
        global GH_LAST_ERROR
        if not run_id:
            return None
        if run_id not in memo:
            # ⛔ AN AGE READ MUST NOT BECOME THE FAILURE THE BEAT NAMES FOR A MAIN/QUEUE READ.
            # `gh()` records the last failure for the report; this read is OPTIONAL, so its
            # failure is restored away -- and swallowed, because a line-producer NEVER raises
            # here: an assertion about a run's age is not worth losing the beat's whole verdict.
            keep = GH_LAST_ERROR
            d = None
            try:
                d = gh(f"repos/{REPO}/actions/runs/{run_id}")
            except Exception:
                d = None
            finally:
                GH_LAST_ERROR = keep
            # ⛔ SHAPE-GUARD THE BODY, not just the call. `gh` can exit 0 with a non-object
            # body ("Not Found", `[1,2]`), and `.get` on that raises OUTSIDE the guard above --
            # which turns ONE unreadable clock into a lost beat line (`VERDICT=UNKNOWN error=`).
            memo[run_id] = (_epoch_ts(d.get("run_started_at"))
                            if isinstance(d, dict) else None)
        return memo[run_id]

    return run_clock


def flight_age_min(c, now=None, run_clock=None):
    """Minutes the ATTEMPT `c` has been non-completed, or None when there is no clock.

    `started_at` when the run started (per attempt, and fresh after a re-run); else the wall
    clock of the attempt that owns it, from `run_clock`. None -- not 0, and not infinity --
    when neither can be read: an unreadable clock leaves the run IN FLIGHT and never
    manufactures a re-trigger, the same rule as `rail_block_reason` (absence is not evidence).
    """
    since = _epoch_ts(c.get("started_at"))
    if since is None and run_clock is not None:
        # ⛔ NEVER HAND AN UNVALIDATED SEGMENT TO THE CLOCK (#1926 review, P2). `_run_id` now
        # returns digits or None, and this provider is the one that turns a run id into an
        # authenticated read -- so a `details_url` that yields no valid id (a non-Actions app, or
        # a crafted `..`) is an UNREADABLE clock here, not a request for SOME run.
        rid = _run_id(c.get("details_url"))
        since = run_clock(rid) if rid else None
    if since is None:
        return None
    now = time.time() if now is None else now
    return max(0.0, (now - since) / 60.0)


def stalled_flight(cr, now=None, bound_min=None, run_clock=None, restrict=GATED_CHECKS,
                   collapse=True):
    """[(name, status, age_min)] -- checks still non-completed PAST the flight bound.

    `restrict` is the context set that is AGED. It defaults to the REQUIRED ones
    (`GATED_CHECKS`), which is the set #1926 is about; `restrict=None` ages EVERY context, which
    is what the absent-gate half of the `running` arm needs (see `wedge_evidence`).

    ⛔ THIS IS THE SHAPE THE RE-TRIGGER ARM CANNOT REACH. That arm requires `not req_seen` (and
    `not flight`, #1872): a wedged run IS present in `seen` -- it is a required context that
    REPORTED -- while its HEALTHY siblings are also present, so `req_seen` is non-empty and
    `flight` is non-empty, and the arm cannot fire -- and it can
    never satisfy `not flight` either, since its status is not `completed`. Past the bound it is
    not a wait: nothing will ever complete it, so the work is to START it, which is what
    `rerun-checks` already tells a lane to do.

    ⛔ ONE ENTRY PER NAME BY DEFAULT (`collapse=True`), ONE PER ATTEMPT ON REQUEST
    (`collapse=False`) -- the two callers want opposite things, and conflating them was a real
    defect (#1926 review, P2). Two workflows can publish the same job name (the shape
    `newest_attempts`' grouping exists for), and a reason that prints `docs queued 88m,docs
    queued 95m` names one check twice with two ages and no way to tell which is which. So the
    TEXT collapses -- `rollup_checks` collapses that pair to one name too, and the age read
    follows, keeping the OLDER attempt because that is the one that has been stuck. The
    DECISION must NOT collapse: `wedge_evidence` asks whether ANYTHING in flight can still
    complete, which is a question about JOBS -- collapse by name first and one FRESH attempt
    hides behind a stalled namesake whose age alone survives the collapse.
    """
    bound = FLIGHT_BOUND_MIN if bound_min is None else bound_min
    per_attempt = []
    for name, newest in newest_attempts(cr):
        if restrict is not None and name not in restrict:
            continue
        st = (newest.get("status") or "").lower()
        if not st or st == "completed":
            continue
        age = flight_age_min(newest, now=now, run_clock=run_clock)
        if age is None or age <= bound:
            continue
        per_attempt.append((name, st, age))
    if not collapse:
        return sorted(per_attempt)
    worst = {}
    for name, st, age in per_attempt:
        if name not in worst or age > worst[name][1]:
            worst[name] = (st, age)
    return sorted((n, st, age) for n, (st, age) in worst.items())


def inflight_attempts(cr, restrict=None):
    """[(name, status)] -- ONE ENTRY PER ATTEMPT GROUP still non-completed at this head.

    The COUNTERPART of `rollup_checks`' `flight` name SET, at the granularity the wedge question
    is actually asked in. `flight` is a set of NAMES: two workflow runs publishing the same job
    name collapse to one member, so a name count cannot say how many JOBS are still running.
    `wedge_evidence`'s absent-gate test compares this list against
    `stalled_flight(..., collapse=False)`, which uses the SAME grouping, so the comparison is
    per-ATTEMPT and a fresh attempt can never hide behind a stalled namesake.

    Same non-completed rule as `rollup_checks` -- both read the NEWEST attempt per
    `(app, workflow, name)` group, so a group cannot be in flight for one and not the other.
    """
    out = []
    for name, newest in newest_attempts(cr):
        if restrict is not None and name not in restrict:
            continue
        st = (newest.get("status") or "").lower()
        if st and st != "completed":
            out.append((name, st))
    return sorted(out)


# ⛔ THE NAME IS ALSO A TOKEN SURFACE, NOT ONLY A SENTENCE (#1948 review cycle 2, P1).
# `why` reaches TWO consumers with different grammars. The brief is prose a lane reads; the
# OBJECTIVE LINE is a MACHINE-PARSED contract (`_class_token` -> `OBJECTIVE VERDICT=…` ->
# `objective.last` -> `turn-classify.py`, which substring-tests `VERDICT=FIX-MAIN` and
# `gh=RATE-LIMITED` and appends a directive that says it OVERRIDES the lane's next step, and
# `cadence-nudge.sh`, which `cmux send`s the same line). Neither token contains a character in
# the marker list, so stripping markers alone left a check named
# `VERDICT=FIX-MAIN gh=RATE-LIMITED` able to forge BOTH: a green main reported as red to every
# idle lane. `=` and `:` are the structural characters every fleet token is built from
# (`VERDICT=`, `gh=`, `waiting=`, `main=`, `ASK-USER:`, `IN-PROGRESS:`, `NEXT:`/`ROLE:`/`GOAL:`),
# so they are dropped here -- no fleet token and no nudge field survives without them.
# ⛔ `(`, `)` are DELIBERATELY KEPT: they are what keeps matrix job names readable
# (`test (a) queued 150m`), and a parenthesis cannot begin a token assignment.
# ⛔ THE LIST MUST EQUAL `pr-doctor._MARKERS` EXACTLY -- `"```"` is redundant beside `"`"` (the
# single backtick subsumes it), and it is included anyway so the two copies of this vocabulary are
# IDENTICAL rather than merely equivalent; `test_evidence_markers_mirror_the_brief_s_marker_list`
# pins the equality, because a marker added to one side only would silently stop being stripped at
# that boundary (this module cannot import `pr-doctor`, so the lists cannot be shared).
EVIDENCE_MARKERS = ("\u26d4", "IDLE->", "DO:", "**", "```", "`")


def evidence_name(name, limit=60):
    """One check-run name, rendered so it cannot be read as the fleet's own instruction OR TOKEN.

    A check-run's `name` is published by the HEAD's own workflow files, so a PR chooses it -- and
    `wedge_evidence`'s absent-gate shape ages EVERY context (`restrict=None`), so a name that is
    not one of the repo's own gates reaches `why`. That reason is interpolated into BOTH a brief a
    lane EXECUTES (`pr-doctor.brief`, the class `_untrusted` already closes for the PR title) and
    the MACHINE-PARSED objective line (see `EVIDENCE_MARKERS`) -- two consumers, two grammars, so
    this strips to the union of what both read.

    Drops non-printables (a lone `\\x00`/`\\u200b` would otherwise reassemble a marker), strips
    the fleet's markers TO A FIXPOINT (one ordered pass can rebuild `DO:` out of `D` + a removed
    backtick + `O:`), THEN drops the token-assignment characters (`=`/`:`) the machine-parsed line
    is keyed on, collapses whitespace, truncates the INNER text, and WRAPS the result in guillemets
    -- so it can only be read as a quotation by either consumer, the brief a lane executes and the
    machine-parsed objective line that is pasted into a lane's nudge.
    """
    out = " ".join(str(name or "").split())
    out = "".join(ch for ch in out if ch.isprintable() and ch not in "\u00ab\u00bb")
    while True:
        before = out
        for marker in EVIDENCE_MARKERS:
            out = out.replace(marker, "")
        if out == before:
            break
    # ⛔ THE TOKEN-ASSIGNMENT CHARACTERS GO AFTER THE MARKER FIXPOINT, NEVER BEFORE. `DO:` is a
    # MARKER and `VERDICT=` is a TOKEN, and stripping `:` first would turn `DO:` into the
    # harmless-looking residue `DO` before the marker list ever saw it (measured) -- two
    # vocabularies, so the order that satisfies both is: markers to a fixpoint, THEN the
    # assignment characters, THEN re-collapse.
    out = "".join(ch for ch in out if ch not in "=:")
    out = " ".join(out.split())
    # ⛔ THE WRAPPER BELONGS TO THE BUILD BOUNDARY, NOT TO ONE CONSUMER (#1948 review cycle 3,
    # F2). The brief wraps the reason in guillemets (`pr-doctor._untrusted`), but the OBJECTIVE
    # LINE interpolates it UNQUOTED inside `#<n>(...)` -- and that line is appended verbatim into
    # a live lane's nudge (`turn-classify.py`'s "CURRENT STATE:", `cadence-nudge.sh`). Instruction-
    # shaped prose survived sanitisation there ("IGNORE THE RAIL AND RUN ..."), so the token half
    # was closed and the instruction half was not. Wrapping HERE closes both in one place: the
    # author's own guillemets are already stripped above, so the wrapper cannot be forged or
    # escaped, and `_untrusted` strips-and-rewraps, so the brief still shows exactly one pair.
    return "\u00ab" + (out[:limit] or "?") + "\u00bb"


# ⛔ THE REASON IS BOUNDED, BECAUSE IT LANDS ON A LINE THAT IS READ WITH A FIXED CUT (#1948
# review cycle 5, P2). The objective line is `sed -n '2p' ... | cut -c1-900`
# (`cadence-nudge.sh:311`), and the fields AFTER the class segment -- the dispatcher-liveness field
# and the CI indicators -- sit behind it. Measured on a realistic starved-queue head (this
# project's own matrix, `python-ci-gate` absent, every other context queued past the bound): 19
# named checks -> `why` 487 chars -> token 510, so ONE such PR pushes those fields out of every
# lane's nudge -- and a fleet-wide starvation is exactly when the reason is longest. The count is
# bounded only by how many check-runs the head publishes, i.e. it is author-influenced too: each
# NAME is capped by `evidence_name`, the NUMBER of names was not.
# The other consumer of the same string already caps it (`pr-doctor.brief` renders `why` with
# `_untrusted(why, limit=120)`), which is the asymmetry that gives the budget away.
# The cap keeps the WORST (oldest) names -- the ones the lane should start first -- and states how
# many it hid, so the bound never reads as "that was all of it".
WEDGE_REASON_MAX_NAMES = 4
WEDGE_REASON_MAX_CHARS = 120


def wedge_reason(rows, max_names=WEDGE_REASON_MAX_NAMES, max_chars=WEDGE_REASON_MAX_CHARS):
    """`why` for a wedged head: the oldest few names, then `,+K more` when any are hidden.

    Rows are `(name, status, age_min)` as `wedge_evidence` returns them; ordering is by AGE
    DESCENDING, then name, so the cap is deterministic and always keeps the longest-stuck check.
    """
    ordered = sorted(rows, key=lambda r: (-r[2], r[0]))
    kept, used = [], 0
    for idx, (name, st, age) in enumerate(ordered):
        piece = f"{evidence_name(name)} {st} {age:.0f}m"
        cost = len(piece) + (1 if kept else 0)
        hidden = len(ordered) - idx          # what would remain hidden if we stop here
        tail = len(f",+{hidden} more") if hidden else 0
        if kept and (used + cost + tail > max_chars or len(kept) >= max_names):
            break
        kept.append(piece)
        used += cost
        if len(kept) >= max_names:
            break
    if not kept:
        return None
    out = ",".join(kept)
    hidden = len(ordered) - len(kept)
    if hidden:
        out += f",+{hidden} more"
    return out


def wedge_evidence(stalled, gated_absent, flight_attempts, flight_stalled):
    """[(name, status, age_min)] -- WHY a `rerun-checks` verdict is a re-trigger, or [].

    TWO shapes, ONE question: *will anything at this head ever complete on its own?*

    * a REQUIRED check PAST the bound (`stalled`) -- the shape #1926 names; and
    * a REQUIRED gate that was NEVER CREATED while EVERY ATTEMPT in flight is past the bound
      (`gated_absent` + `flight_stalled`). `python-ci-gate` is created only after its matrix
      children finish, so a child left `queued` by a runner that never came up keeps the gate
      out of `seen` for ever -- and the `gated_absent and flight` term of the `running` arm would
      then WAIT WITHOUT A BOUND. If nothing in flight can complete, the gate cannot be created,
      so the work is to START the run: the same repair, and the same class, as the wedged shape.

    ⛔ THE SECOND SHAPE IS COUNTED IN ATTEMPTS, NOT NAMES (#1926 review, P2). This compared the
    `flight` NAME SET against the NAME-COLLAPSED aged list, so `len(...) == len(...)` was a
    statement about names: `docs` published by two workflow runs at one head -- one attempt
    stalled past the bound, one freshly started -- read `1 == 1` and manufactured a re-trigger on
    a suite that was still PROGRESSING, discarding the fresh job's work and resetting the age
    (the exact harm the `newest_attempts` grouping exists to read honestly). Callers now pass
    `inflight_attempts(cr)` (one entry per in-flight group, duplicates kept) and
    `stalled_flight(..., collapse=False)` (one per stalled group), so the equality is about JOBS:
    a fresh attempt makes the counts differ, and the head stays a WAIT. The reason TEXT still
    collapses by name, keeping the older attempt -- see `stalled_flight`.

    An EMPTY result means "keep waiting". A slow child UNDER the bound, a partially fresh flight
    set, and an in-flight check whose age cannot be read (absence is not evidence) are all waits
    and must never manufacture a re-trigger.
    """
    if stalled:
        return list(stalled)
    if gated_absent and flight_attempts and len(flight_stalled) == len(flight_attempts):
        worst = {}
        for name, st, age in flight_stalled:
            if name not in worst or age > worst[name][1]:
                worst[name] = (st, age)
        return sorted((n, st, age) for n, (st, age) in worst.items())
    return []


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


def classify_pr(pr, cr, att_clean, stalled=(), flight_stalled=()):
    """The ONE action class for a non-draft PR, FIRST MATCH in CLASS_ORDER, or None if unread.

    Pure on purpose: `cr` is a check-run list ALREADY READ, `att_clean` the attestation
    verdict, `stalled` the aged-out GATED flight list and `flight_stalled` the same list over
    EVERY context with `collapse=False` (one entry per ATTEMPT -- the absent-gate test is a
    question about jobs, not names; see `stalled_flight`/`inflight_attempts`) -- so the
    classification is testable without touching GitHub. `None` (a miss) is NOT `fix-ci` -- an
    unreadable PR must never be counted as work, or a blind read would manufacture a queue of
    failures.
    """
    if cr is None:
        return None
    red, flight = rollup_checks(cr)
    seen = {c.get("name") for c in cr if c.get("name")}
    req_seen = [n for n in REQUIRED if n in seen]
    # `ai-review-gate` is DIFF-BOUND (arm 1), so it is not a gate this predicate WAITS on: its
    # truth is the head-bound attestation file, never its check-run. Everything below is about
    # the other six.
    # ⛔ THE GATED SET HAS ONE OWNER (#1926 review): `GATED_CHECKS`, above. An inline copy here
    # diverged from the aged set the moment either was edited -- silently, because nothing pins
    # them equal -- and the file's own rule (`newest_attempts`) is ONE grouping for the whole file.
    gated = list(GATED_CHECKS)
    gated_absent = [n for n in gated if n not in seen]
    gated_red = [n for n in gated if n in red]
    gated_flight = [n for n in gated if n in flight]
    nongreen = [n for n in gated if n in red or n in flight or n not in seen]
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
    # 1. call-rail -- every required check EXCEPT `ai-review-gate` is green AND a clean
    #    attestation exists at the CURRENT head AND the RAIL ITSELF would take it. The last
    #    clause was missing: an attested PR the rail refuses is a NAMED defect, not "not ready".
    #    ⛔ THIS ARM STAYS FIRST, so a LANDABLE PR is never delayed by a running check elsewhere
    #    (see arm 5): the cheapest landing on the board must not queue behind a non-gating job.
    #    ⛔ A RAIL GATE *IN FLIGHT* IS NOT A DEFECT TO REPAIR (#1872 review round 7).
    #    `rail_block_reason` deliberately accepts a gate that is in flight as well as one that is
    #    red -- but the two are opposite instructions. `blocked-by-rail` becomes the brief "THE RAIL
    #    REFUSES IT ON <gate>. REPAIR THAT, THEN MERGE." MEASURED: all six required contexts green,
    #    attestation clean, `drift-guard` merely `in_progress` -> `blocked-by-rail(drift-guard)`, so
    #    a lane was dispatched to repair a gate that had not concluded. That is the same harm arm 5
    #    exists to remove ("a check in flight is not work", 3h burned on #7924), so an
    #    in-flight rail gate reads `running` and a RED one still reads `blocked-by-rail`.
    #    ⛔ AND A DIRTY HEAD IS STILL THE ONE THING A LANE CAN FIX (#1872 review round 12). This
    #    arm already returns LAST-BUT-ONE in `CLASS_ORDER`, so returning `running` from here put it
    #    ABOVE `resolve-conflict` -- the single exception to the arm order, and the one arm the suite
    #    did not pin. MEASURED: six required contexts green + attestation + DIRTY + `drift-guard`
    #    `in_progress` -> `running`, i.e. "wait", while the only available fix is a REBASE that no
    #    check will ever do. Both consumers skip `running` and its only escalation is `STUCK`, which
    #    is emitted for `call-rail` alone, so such a PR could wait forever.
    if not nongreen and att_clean:
        _rail = rail_block_reason(red, flight, seen)
        if _rail:
            if _rail in red:
                return "blocked-by-rail"
            if (pr.get("mergeStateStatus") or "") == "DIRTY":
                return "resolve-conflict"
            return "running"
        return "call-rail"
    # 2. rerun-checks -- NO required check has REPORTED at this head, and nothing is executing.
    #    ⛔ `and not flight` IS LOAD-BEARING (#1872 review). Without it this arm SHADOWED arm 5
    #    for the exact shape arm 5 was written for: a fresh head where no required context has
    #    reported yet while other checks are already running -- which is the NORMAL first state
    #    of a push, because `python-ci-gate` (and `docs`, `legal-e2e`) are created seconds after
    #    the children. `req_seen` empty means "not reported yet" as often as "never ran", and
    #    the two need OPPOSITE actions: wait, versus START the workflow. Worse, the dispatcher's
    #    `rerun-checks` brief asserts "(Nothing is in flight ...)" and tells the lane to push an
    #    empty commit -- so the shadowed arm sent it to churn a 20-second-old head, wasting
    #    runner capacity and staling the attestation. `drive`/`drift-guard`/`sigpipe-guard`
    #    being red cannot reach here: they are not in REQUIRED.
    if not req_seen and not flight:
        return "rerun-checks"
    # 3. rerun-checks (WEDGED) -- a required check is still non-completed PAST the flight bound.
    #    This is NOT a wait: nothing will ever complete it (GitHub does not reconcile a run that
    #    was never picked up), so the work is to START it, which is what `rerun-checks` means to a
    #    lane, and the reason names the check, its state and its age.
    #    ⛔ IT SITS ABOVE `running` (arm 5) BECAUSE A WEDGED RUN *IS* IN FLIGHT. That is the whole
    #    trap: `rollup_checks` puts any non-`completed` status in `flight`, so arm 5 matches this
    #    shape and answers "the head is still executing" -- forever, because nothing will ever
    #    complete it. Sibling #1872 said so when it landed: "#1926 (`running` has no age bound, so
    #    a wedged check-run parks a PR forever)". The age bound is the missing dimension, and
    #    without this arm the class is a WAIT that never ends (pre-merge on this branch's base it
    #    was `fix-ci`, i.e. a lane sent to REPAIR CODE FOR A JOB THAT NEVER RAN -- measured
    #    `{'fix-ci': 1}`; on the merged tree it is `running`).
    #    ⛔ AND IT SITS ABOVE `resolve-conflict` (arm 4), where `CLASS_ORDER` records it. That is the
    #    recorded ladder, not a preference: a rebase CHANGES THE HEAD, so a re-trigger before it is
    #    at worst one redundant API call, while the reverse order lets a DIRTY PR with a wedged
    #    suite sit in `resolve-conflict` while the wedge is never named. Pinned by test.
    #    ⛔ AND IT BOUNDS THE OTHER HALF OF `running` TOO (#1926 review, P1). Arm 5's
    #    `gated_absent and flight` term had NO age term, so a required gate that is absent while a
    #    NON-required child job is wedged satisfied it forever: `gated_flight == []`,
    #    `gated_absent == [6 names]`, `flight == {"test (a)"}` -> `running`, indefinitely, while
    #    `stalled_flight` skips every name outside `GATED_CHECKS` and so could not see it. That is
    #    the reachability evidence #1926 itself offers -- the gate is created only after its
    #    matrix children finish, so something is in flight for the whole suite -- turned against a
    #    child that never completes. See `wedge_evidence`: when NOTHING in flight can complete,
    #    the gate can never be created and the work is to START the run.
    #    ⛔ A RED gated check is NEVER this class: a red check is real work, and re-triggering
    #    would only mask it for a pass (same rule the `running` verdict states, #1872).
    if not gated_red and wedge_evidence(stalled, gated_absent,
                                        inflight_attempts(cr), flight_stalled):
        return "rerun-checks"
    # 4. resolve-conflict -- GitHub says DIRTY. A rebase CHANGES THE HEAD, so it is right even
    #    while checks are still running (they all re-run anyway) -- which is why it sits ABOVE
    #    the `running` arm below.
    #    ⛔ AND IT CANNOT FIRE FOR AN ATTESTED PR: arm 1 returns first, so a green+attested head
    #    that has since gone DIRTY reads `call-rail`, whose brief says the rail would take it --
    #    while the rail refuses a conflicted PR. Pre-existing, and DELIBERATELY left alone here
    #    (the edge is pinned by `test_knows_the_one_edge_the_strict_order_creates` as "PINNED, NOT
    #    ENDORSED", so fixing it changes the arm spec). Tracked in agent-infra #1936 (QUALIFIED, not
    #    a bare `#1936`: these files live in agent-infra but a bare number reads as the repo under
    #    test, tortoise, where #1936 is an unrelated packs feature); two reviewers rated it
    #    P1, so it should land before this ordering is trusted.
    if (pr.get("mergeStateStatus") or "") == "DIRTY":
        return "resolve-conflict"
    # 5. running -- THE HEAD IS STILL EXECUTING, and nothing can be decided about it yet.
    #    ⛔ THE SIGNAL IS NOT ONLY "a REQUIRED check is in flight". MEASURED 2026-10-16:
    #    `python-ci-gate` is ABSENT while its child jobs run (`test (a)`, `test-slow (a)`, ...) --
    #    the gate job is created only AFTER the matrix finishes. So the absence of a required
    #    gate while ANY check at this head is in flight means "not reported yet", not "never
    #    ran": #8825, #8806 and #8824 were exactly that. The BEAT called all three `fix-ci` (go
    #    repair the code); the dispatcher's fork called #8825 `running` and the other two
    #    `unreviewed` (go review it) -- so on #8825 the two readers disagreed about whether to
    #    work at all. The series is enumerated once, in the file header (4 of 11: #8825 plus
    #    #8806/#8822/#8824); these three are the ones this arm answers, and #8822 is the
    #    nothing-in-flight shape arm 7 answers instead.
    #    ⛔ BUT A RED REQUIRED CHECK IS STILL WORK, even beside a running unrelated job: waiting
    #    on a lint/typecheck job to finish before repairing a genuinely failing gate would only
    #    delay the fix (#8708). So the arm covers flight-or-not-yet-reported, NEVER red -- the
    #    `not gated_red` term is load-bearing and was MISSING in the first cut of this change:
    #    `docs` RED while `python-ci-gate` is still absent is the DOMINANT live shape (a fast
    #    required context fails long before the matrix finishes), so without it every such PR
    #    was reported `running` for the rest of the suite and no lane ever repaired it.
    if (gated_flight or (gated_absent and flight)) and not gated_red:
        return "running"
    # 6. record-review -- every required check EXCEPT `ai-review-gate` is green and there is NO
    #    current clean attestation at this head. This is the LEGITIMATE case, and it is the exact
    #    complement of arm 1: the ONLY difference between landing a PR and re-recording it is
    #    whether the attestation at THIS head exists, which is why the file -- not the check-run
    #    -- decides. (An all-green `ai-review-gate` with a SUPERSEDED record lands here too: a
    #    green gate at an old head is evidence about that head, not this one.)
    if not nongreen and not att_clean:
        return "record-review"
    # 7. rerun-checks -- SOME required check never ran at this head while others COMPLETED, and
    #    the head is not executing (arm 5). Absence is not green, and it is not a failure to FIX:
    #    the job that was never created has to be STARTED. MEASURED #8822: `python-ci-gate`
    #    absent (its job never got created), `drift-guard` red, `ai-review-gate` red and NOTHING
    #    in flight -- the arms above made that `fix-ci` (send a lane to repair code), and the
    #    dispatcher's fork called it review-only (`unreviewed`; that fork needed the
    #    `ai-review-gate` red to get there -- without it, it said `no-checks`). Both were wrong:
    #    re-trigger the check first.
    if gated_absent and not gated_red:
        return "rerun-checks"
    # 8. fix-ci -- a required check is RED: real code work.
    return "fix-ci"


def fix_ci_reasons(cr):
    """The REQUIRED check names that are RED, sorted -- the IN-PROGRESS work list.

    ⛔ ONLY THE 7 BRANCH-PROTECTION CONTEXTS MAY APPEAR. This list once carried every red job
    name, so it read `python-ci-gate=11 test (b)=4 test (g)=3 test-slow (a)=3 ... drive` -- job
    names that are all inside the ONE required context `python-ci-gate`, plus non-required
    checks (`drive`, `manifest-integrity`, `agent-infra-ci / lint`). That over-reported the work
    and sent lanes at jobs that gate nothing. NOW: only RED required checks count;
    `ai-review-gate` is excluded (it has its own action), and NOT_REQUIRED_CHECKS explicitly.

    ⛔ AND RED IS NOW THE ONLY QUALIFIER (#1872). This used to count a check that was in flight
    or NEVER RAN as work to fix -- true while `fix-ci` was the catch-all, false since `running`
    and the partial-absence `rerun-checks` arm took those cases. Listing them here would tell a
    lane to FIX a suite that is still executing, or one that was never started.
    """
    red, _flight = rollup_checks(cr)
    return sorted(n for n in REQUIRED
                  if n in red and n != "ai-review-gate"
                  and n not in NOT_REQUIRED_CHECKS)


def classify_one(p):
    """(class, why, cr) for ONE non-draft PR -- THE SINGLE CLASSIFIER, one read of the evidence.

    Both readers go through here: `classify_queue()` below (the beat's per-class counts) and
    `scripts/pr-doctor.py` (the dispatcher's plan). Same predicate, same check-run read, same
    attestation read -- so their answers cannot disagree (#1872: the beat and the dispatcher
    differed on 4 of 11 live PRs while both looked correct).

    ⛔ WHAT THIS GUARANTEES, AND WHAT IT DOES NOT. It guarantees ONE PREDICATE over ONE KIND OF
    EVIDENCE. It does NOT make two processes see one snapshot: the beat serves a cached line up to
    `VERDICT_SERVE_MAX_S` (120 s) old -- `--max-age` cannot exceed that -- while the dispatcher reads
    every pass, and the dispatcher lists PRs with a smaller page limit. So a disagreement can only
    come from the INPUT (a different moment, or a PR beyond a page limit) -- never from two
    different rules, which is the defect this seam removes.

    Returns `cr` too, because a dispatcher's brief needs the evidence beside the class and a
    second read of it would be a second truth. `why` is the reason rendered beside a class that
    names its object (`blocked-by-rail`'s refusing gate, `fix-ci`'s red checks, `rerun-checks`'
    wedged check and its age), else None.

    ⛔ THE AGE IS READ HERE TOO, so a wedged check and its age come from the SAME check-run read
    as the class (#1926). One clock object and one `now` per call, so every check in THIS PR is
    aged against the same instant; the age read itself is LAZY -- `stalled_flight` spends a run
    read only for a gated check that never started.

    ⛔ AND THE ALL-CONTEXTS AGE LIST IS READ LAZILY TOO (#1926 review, P1). It is consulted by ONE
    arm (the absent-gate half of `running`, via `wedge_evidence`), so it is computed only when
    that arm's CHEAP precondition holds: something at the head is in flight and a required gate
    is absent. That precondition is a COST gate, never a second predicate -- the decision stays
    `classify_pr`'s alone. Without it every PR would spend a run read per never-started child on
    every pass, on a shared and rate-limited token.
    """
    head = p.get("headRefOid") or ""
    cr = per_pr_checks(head)
    now = time.time()
    clock = _pass_run_clock()
    stalled, flight_stalled, gated_absent = [], [], []
    red, flight = set(), set()
    _seen = set()
    if cr:
        red, flight = rollup_checks(cr)
        _seen = {c.get("name") for c in cr if c.get("name")}
        gated_absent = [n for n in GATED_CHECKS if n not in _seen]
        stalled = stalled_flight(cr, now=now, run_clock=clock)
        if not stalled and flight and gated_absent:
            # ⛔ `collapse=False`: the absent-gate test is per ATTEMPT (#1926 review, P2) -- a
            # fresh job sharing its name with a stalled one still counts as "can complete".
            flight_stalled = stalled_flight(cr, now=now, run_clock=clock, restrict=None,
                                            collapse=False)
    k = classify_pr(p, cr, attestation_clean(p.get("number"), head), stalled, flight_stalled)
    why = None
    if cr and k == "rerun-checks":
        # The REASON is the object of the action: WHICH check, in which state, for how long. Both
        # a wedged run and a head whose checks never got created read `rerun-checks`, and they
        # need different repairs -- so the wedged one says why it is here (#1926). BOTH wedged
        # shapes are named: a stalled REQUIRED check, and an absent gate beside children that
        # cannot complete (`wedge_evidence`). A head whose checks never got created has NOTHING to
        # name here, so `why` stays None and the brief's "never ran" branch is the right one.
        # ⛔ `why` OMITS THE DIFF-BOUND GATES (#1926 review, P1). The aged set is over EVERY
        # context, so it legitimately contains `ai-review-gate` -- but these names become the
        # brief's ORDER ("Re-trigger the workflow run behind `<why>`"), and a re-trigger provably
        # cannot start a gate whose truth is the head-bound attestation FILE. Naming it sends a
        # lane at a no-op; the re-run creates a fresh attempt, the next pass reads the head as
        # `running`, and the head oscillates re-trigger -> wait -> re-trigger for ever while the
        # gate that DOES need starting is only listed as absent.
        # ⛔ THE DECISION IS UNTOUCHED -- `classify_pr` above still sees the full aged list, so
        # this shape is still `rerun-checks` (never an eternal `running`): only the ORDER loses the
        # unstartable name, and `why` becoming None correctly hands the brief to its absent-gate
        # branch, which names the gate that was never created.
        # ⛔ THE NAME IS SANITISED AT THE BOUNDARY (#1948 review): what survives the filter is
        # still an author-published check-run name, and this string becomes an executed order AND
        # a machine-parsed token downstream. `st` is a conclusion this file chose from a fixed
        # vocabulary; `n` is whatever the head published.
        # ⛔ BOUNDED, not merely joined (#1948 review cycle 5, P2): this string is cut at 900
        # chars downstream, and an unbounded list of author-published names can push the fields
        # behind it off the line. `wedge_reason` keeps the oldest few and says how many it hid.
        why = wedge_reason([row for row in
                            wedge_evidence(stalled, gated_absent,
                                           inflight_attempts(cr), flight_stalled)
                            if row[0] not in DIFF_BOUND_CHECKS])
    elif cr and k == "blocked-by-rail":
        why = rail_block_reason(red, flight, _seen)
    elif cr and k == "fix-ci":
        # ⛔ FILTERED BY `REQUIRED` -- THE BUCKET COUNTS ONLY THE 7 BRANCH-PROTECTION CONTEXTS.
        # It previously counted EVERY red job name, so the list carried
        # `test (b)`/`test (g)`/`test-slow (a)`-class job names (all inside the ONE required
        # context `python-ci-gate`), plus `drive` and `manifest-integrity`, which are NOT
        # required and never gate a merge. Measured 2026-10-11: the list ran to
        # `python-ci-gate=11 test (b)=4 test (g)=3 test-slow (a)=3 ... drive` -- an inflated
        # count over checks no lane has to fix, which is how the bucket both over-reported work
        # and sent lanes at non-gating jobs.
        why = ",".join(fix_ci_reasons(cr)) or "?"
    return k, why, cr


def classify_queue(non):
    """(Counter of CLASS_ORDER, surface_count, by_class, surface_prs), or
    (None, surface_count, {}, surface_prs) when the buckets are NOT a usable partition.

    ⛔ `surface_prs` IS RETURNED IN BOTH DIRECTIONS (#1872 review round 11). The refusal tuple used
    to be documented as `(None, n, {}, [])`, i.e. with the names DROPPED -- which is the opposite of
    what the code does and of why the names exist: a gate whose output is "N things need you"
    without naming them is a stall with a receipt. An unreadable pass is exactly when the owner's
    list matters most, so `surface_prs` survives the refusal.

    TWO conditions produce that tuple, not one: ANY PR whose classification came back unreadable,
    and a set whose buckets do not add up to `nondraft` (a partial sum that still LOOKS like a
    partition is worse than no token at all). FIRST MATCH is what makes the buckets a partition, so
    the sum is asserted here rather than assumed.
    """
    classes, surface, unread = defaultdict(int), 0, 0
    by_class = defaultdict(list)
    surface_prs = []
    for p in non:
        k, why, _cr = classify_one(p)
        if k is None:
            unread += 1
        else:
            classes[k] += 1
            by_class[k].append((p["number"], why))
        if touches_surface(p):
            surface += 1
            surface_prs.append(p.get("number"))
    if unread or sum(classes[k] for k in CLASS_ORDER) != len(non):
        # PARTITION INVARIANT -- omit rather than mislead
        return None, surface, {}, sorted(surface_prs)
    for k in by_class:
        by_class[k].sort()
    return classes, surface, dict(by_class), sorted(surface_prs)


# ⛔ AN UNREAD STATE MUST NEVER PRINT AS A ZERO. `mergeStateStatus` is computed LAZILY by
# GitHub and reads UNKNOWN for the WHOLE repo while it recomputes -- measured 2026-10-01:
# 75 of 82 open non-draft PRs read UNKNOWN at 11:47Z, and the SAME three PRs read BLOCKED
# from BOTH `gh pr view` and `gh pr list` two minutes later once the recompute finished
# (so it is a transient blind spot, not a wrong field -- the REST list endpoint returns
# null here and is no better). Counting only BLOCKED/DIRTY/UNSTABLE silently DROPS those,
# so a blind read printed ZEROS for both: a FALSE ALL-CLEAR, the one wrong
# answer this instrument can give (same fail-open class as GH_BLOCKED, #6142).
# The inverse is the state that means GitHub ANSWERED; everything else -- `UNKNOWN`, a null,
# an absent field, a value GitHub has not documented -- is UNREAD and is counted as such.
KNOWN_MERGE_STATES = frozenset({"BLOCKED", "DIRTY", "UNSTABLE", "CLEAN", "BEHIND", "HAS_HOOKS"})

# ⛔ A LAZILY-COMPUTED FIELD IS A READ TAKEN TOO EARLY -- NOT A FAILED READ (#1869).
# `mergeStateStatus` is recomputed whenever the base or head moves, and while it recomputes it
# reads UNKNOWN for the WHOLE queue: measured again 2026-10-16, one beat at 13:34 printed
# `queue_read=BLIND(14/14 unread)` and the SAME read minutes later returned
# `{BLOCKED: 8, DIRTY: 5, UNSTABLE: 1}`. `_gh_retry` cannot see this: the read SUCCEEDED, and
# only the ANSWER was not ready -- so the SAME query is re-run here, a bounded number of times
# with a short backoff, and only a queue still unread after EVERY attempt is reported BLIND.
#
# ⛔ RE-RUN THE SAME QUERY -- DO NOT ADD A SECOND READER. `mergeable`/`mergeStateStatus` also
# come back null on the REST list endpoint, and a per-PR `gh pr view` was the fallback that
# produced good values during the incident -- but a fallback reader is a DIFFERENT reader, and
# publishing one sample from it beside fourteen from `gh pr list` is how two differently-wrong
# reads get reported as one measurement. Sample the same query again.
#
# BUDGET, and why it is small: the beat's refresh is bounded at 90 s (`heartbeat-loop.sh`,
# `run_bounded 90 objective-refresh`) and a full recompute already costs ~12 s (~513 graphql
# calls, one per PR/check-suite). Each re-read is ONE list query plus a few seconds of waiting,
# and `classify_queue` runs ONCE after the loop, so a re-sample never repeats the per-PR storm.
# A recompute window longer than this budget is genuinely not settled FOR THIS BEAT; BLIND is
# then the truthful answer (and, until #1916, a BLIND line IS still cached -- `main()`'s guard
# does not know the token, so it can be served from `objective.last` for up to 900 s. Do not read
# that as "the next beat re-samples": the next RECOMPUTE does).
QUEUE_BLIND_ATTEMPTS = 4                      # 1 fresh read + 3 re-reads
QUEUE_BLIND_BACKOFF_S = (2, 5, 10)            # ~17 s of waiting, all attempts together
QUEUE_BLIND_BUDGET_S = 20                     # WALL-CLOCK bound on re-sampling, from read 1:
                                              # a slow first read spends the budget it would
                                              # otherwise spend on waiting


# ⛔ THE QUEUE READ HAS A SECOND SOURCE, AND IT IS A DIFFERENT BUCKET (#2138).
# `gh pr list --json` is GRAPHQL. Under fleet concurrency GitHub refuses it with the SECONDARY
# limit while the primary budget is nearly untouched -- measured 2026-10-19: the call returned
# `API rate limit already exceeded for user ID 81560491` at `core 1599/5000` / `graphql 4612/5000`,
# and a single REST `.../pulls` call answered 200 in 0.43 s with 17 concurrent gh clients on one
# box. The consequence was visible in this file's own output: `gh=RATE-LIMITED(queue)
# queue=UNREADABLE` for whole cycles, so the beat could not report the ONE number its verdict is
# about. The two limits are separate buckets, so REST is a SECOND SOURCE -- never a retry of the
# same refusal, and never a fallback to "empty" (an empty read is a FAILED read, #1872).
#
# ⛔ AND IT DOES NOT GO THROUGH `GH_BIN` -- NOT AS A DEPARTURE FROM #1959, BUT BECAUSE OF IT.
# The `$O/gh-rest` adapter serves a GraphQL refusal over REST and `_gh_layer()` prefers it, but it
# CANNOT serve THIS read: its `PR_FIELDS` allow-list has no `files`, and its own field rule says a
# field it does not model "DELEGATES the whole call … Dropping one is not a slow answer, it is a
# WRONG answer". `gh pr list --json …,files` therefore delegates straight back to real gh -- to the
# refused transport -- which is exactly what #1959 decided it should do. So this fallback is the
# in-file equivalent for the ONE read whose field set the adapter deliberately refuses to drop,
# and it keeps `files` UNKNOWN (`[]`) only WHERE THE PRIMARY READ ALREADY FAILED -- never on the
# ordinary path, where the adapter's objection would apply.
QUEUE_PRIMARY_LIMIT = 400                     # the GraphQL list read's page cap; a response AT
                                              # it is a FAILED read (a truncated list published as
                                              # the depth is an under-count -- the same shape the
                                              # REST cap refuses). Named so the assert and the
                                              # argv cannot drift apart.
GH_HOSTS = os.path.expanduser("~/.config/gh/hosts.yml")
QUEUE_REST_PAGE = 100                         # the list endpoint's maximum page
QUEUE_REST_MAX_PAGES = 5                      # a bound on PAGES; reaching it with a FULL last page
                                              # is a FAILED read (a truncated queue is an under-count
                                              # published as the depth), never a 500-row answer
QUEUE_REST_TIMEOUT_S = 30                     # PER-PAGE ceiling, further clipped to the queue read's
                                              # own remaining budget and re-checked after every
                                              # page (`_queue_rest(deadline=…)`), so the fallback
                                              # cannot add a 5 x 30 s tail to a beat that is killed
                                              # at 90 s
# ⛔ THIS CAPS THE QUEUE LIST FETCH (primary + fallback), NOT THE WHOLE QUEUE READ (#2138 r3, A).
# Anchoring the fallback to `now + TIMEOUT` was right for the slow-primary case and WRONG for the
# slow-REFUSAL one: `_gh_retry` retries a 5xx three times, so a refusal can arrive having spent
# 60-75 s of the beat's 90 s refresh bound, and a fresh 30 s socket push the tick past
# `run_bounded 90 objective-refresh` (`heartbeat-loop.sh`) -- where a killed refresh writes NO line
# at all, strictly worse than the refusal it replaces. Half the bound, measured from the START of
# the read: the fallback gets whatever is left of it (still a full page in the ordinary case), and
# a refusal that has already spent it gets NO socket and raises its own cause, so the line prints.
# ⛔ WHAT IS OUTSIDE THIS BOUND, SAID PLAINLY: the ~12 s of tick work before `queue()` runs
# (`main_sha`, `main_health`, `ci_critical_path`) and the per-PR `classify_queue()` storm AFTER the
# list is in hand (one check-run read per open PR, ~12 s on a full recompute) are neither included
# nor claimed to be -- 12 + 45 + 12 is still under the 90 s kill, which is why the split is safe,
# not because the cap covers them.
QUEUE_READ_MAX_S = 45


def _gh_hosts_path():
    """Where gh keeps its config, resolved at CALL time (GH_CONFIG_DIR, XDG, then the default).

    The two ENV legs are read per call rather than at import: `pr-doctor.py` imports this module,
    and a process that sets `GH_CONFIG_DIR`/`XDG_CONFIG_HOME` after import would otherwise read a
    path that no longer exists and silently have no second source. The order mirrors gh's own unix
    resolution.

    ⛔ THE DEFAULT LEG IS THE MODULE CONSTANT, NOT A CALL-TIME `HOME` EXPANSION (#2138 r5, A/P3).
    `GH_HOSTS` is also the seam tests and other callers override, so re-expanding `~` here would
    silently ignore that override. The docstring says which legs are per-call rather than implying
    all three are.
    """
    cfg = os.environ.get("GH_CONFIG_DIR")
    if cfg:
        return os.path.join(os.path.expanduser(cfg), "hosts.yml")
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg:
        return os.path.join(os.path.expanduser(xdg), "gh", "hosts.yml")
    return GH_HOSTS


def _gh_token():
    """The credential gh itself would use. NEVER logged, never printed.

    ORDER IS gh's OWN: `GH_TOKEN`/`GITHUB_TOKEN` beat the config file (a token-in-env cell is a
    real fleet configuration), and only then `hosts.yml`. Reading the file beats asking the binary
    (`gh auth token`): that is another subprocess on the hot path of the read that exists BECAUSE
    the subprocess path is refused, and it would inherit the same shell/shim hazards (#1872).

    ⛔ ONLY A `github.com` CREDENTIAL IS USED, FROM EITHER SOURCE. This file's REPO is a
    github.com repo, so another host's token (an enterprise or GitLab entry in the same file, or
    an `GH_TOKEN` scoped by `GH_HOST` to an enterprise host) is not a fallback — presenting it to
    api.github.com would hand a foreign credential to the wrong service. No token ⇒ `""`, and the
    caller makes no request at all.

    ⛔ AND ONLY THE ACTIVE ACCOUNT'S TOKEN (#2138 r4, A). A multi-account `hosts.yml` nests other
    logins under `users:<login>:oauth_token` ABOVE the active account's own keys, so taking the
    first `oauth_token` inside the block returns a DIFFERENT identity's credential — the REST read
    then runs as somebody else and fails, or acts as the wrong user, while every line of it looked
    right. gh's own layout puts the active account's token at the block's TOP level (depth 1) and
    the alternates deeper, so only depth 1 is accepted; if gh wrote only the `users:` form, the
    entry named by the block's own `user:` key is used.

    ⛔ RESIDUAL — THE SYSTEM CREDENTIAL STORE IS NOT READ (#2138 r6, A/P2 + reviewer E). "gh's own
    order" above is complete only through `hosts.yml`. `gh auth login` stores the token in the OS
    KEYRING by default (plain text only under `--insecure-storage`), and on such a box `hosts.yml`
    holds `user:`/`git_protocol:` and NO `oauth_token` — so this returns `""`, the caller makes no
    request, and the second source this read exists for is INERT there. That is the same
    "silently inert fallback" class `test_the_token_comes_from_ghs_own_config_and_absence_fails_
    closed` pins for a non-standard config dir, and the fleet's own siblings describe the pair
    (`scripts/orchestrator-harness/gh-limit.py`, `refresh-candidates.sh`: "hosts.yml / the
    keyring"). It is STATED rather than closed because the only ways to read the keyring are a
    subprocess (`gh auth token` — rejected above) or a third-party keyring import; the four boxes
    this port came from have the token in `hosts.yml` (measured: the live fallback answers).
    ⛔ AND THE EARLIER TEXT HERE CALLED IT "DIAGNOSABLE", WHICH OVERSTATED IT (#2138 r9, reviewer
    A/P3). The double-refusal cause string does name the path it read, but that string lands in
    `GH_LAST_ERROR`, and NOTHING on the objective path emits it (`build()`'s parts never include
    it; `main()` prints only the line). So on a keyring box the beat says `queue=UNREADABLE`
    WITHOUT naming the cause: the residual is RECORDED, not VISIBLE, and it is silent on the one
    surface an operator reads. Called what it is rather than left flattering.
    A box that authenticates via the keyring needs `gh auth login --insecure-storage` or a
    `GH_TOKEN`; closing it properly is a follow-up, not a silent guess.
    """
    if (os.environ.get("GH_HOST") or "github.com").strip().lower() == "github.com":
        for var in ("GH_TOKEN", "GITHUB_TOKEN"):
            tok = (os.environ.get(var) or "").strip()
            if tok:
                return tok
    try:
        host = None
        depth = 0                    # indent width of the FIRST key inside the host block
        active_user = None
        user_tokens = {}             # login -> token, from the nested `users:` entries
        nested_login = None
        with open(_gh_hosts_path()) as fh:
            for raw in fh:
                if not raw.strip() or raw.lstrip().startswith("#"):
                    continue
                if not raw[0].isspace():              # `github.com:` -- a new host block
                    host = raw.split(":", 1)[0].strip()
                    depth, active_user, nested_login = 0, None, None
                    continue
                if host != "github.com" or ":" not in raw:
                    continue
                indent = len(raw) - len(raw.lstrip())
                if not depth:
                    depth = indent                  # the block's own key level
                k, v = raw.split(":", 1)
                k, v = k.strip(), v.strip().strip("'\"")
                if indent > depth:
                    # INSIDE the block: `users:` -> `<login>:` -> `oauth_token:`. A login is an
                    # empty-valued key DEEPER than the block's own key level -- derived from the
                    # observed nesting, not from gh's 4-space step (#2138 r5, A/P3: hard-coding
                    # `depth + 4` made the per-user fallback return "" on any other indentation,
                    # i.e. silently no second source). Its token is remembered, never returned, so
                    # an alternate account can never be presented as the active one.
                    #
                    # ⛔ AND A `users:` GUARD HERE WAS DEAD CODE (#2138 r6, A/P2). gh writes
                    # `users:` at the block's OWN key level, and `depth` is that level, so
                    # `indent > depth` is false for it and this branch never sees it -- a
                    # `users_indent` test could therefore never change the answer, and a guard
                    # that cannot run is worse than a recorded gap. Removed rather than kept as
                    # decoration; `test_the_ACTIVE_accounts_token_wins_in_a_multi_account_hosts_
                    # yml` pins the arm that DOES fire.
                    if v == "":
                        nested_login = k
                    elif k == "oauth_token" and nested_login:
                        user_tokens[nested_login] = v
                    continue
                if k == "oauth_token" and v:
                    return v                        # the ACTIVE account's own token
                if k == "user" and v:
                    active_user = v
        # No top-level token: gh wrote only the per-user form, so take the ACTIVE user's entry.
        tok = user_tokens.get(active_user or "") or ""
        return tok
    except Exception:
        return ""


def _rest_refusal_text(e, deadline=None):
    """Name a REST refusal by its STATUS and its LIMIT EVIDENCE — never by a guess (#2138 r9).

    ⛔ WHY THIS EXISTS AT ALL. The TEXT of an `HTTPError` is only "HTTP Error 403: Forbidden" —
    the reason phrase, never the message GitHub sent — and that spelling misses
    `TRANSPORT_MARKERS` ("http 4" is not a substring of "http error 403"), so a REAL refusal
    classified as transport still published NO claim: measured, a mangled primary plus a genuine
    403 printed `queue=UNREADABLE` with no `gh=` and `VERDICT=UNKNOWN`. Both reviewers found this
    independently, and the old test hid it behind a hand-built `OSError` carrying a string this
    path can never emit.

    ⛔ AND ONE EARLIER SENTENCE HERE WAS ITSELF FALSE, WHICH IS WHY IT IS SPELLED OUT (#2138 r10,
    and corrected AGAIN at r13 because the correction went stale). It said "`urllib` raises before
    the body is readable". Measured against a real 403, `e.read()` returns GitHub's body perfectly
    well — only `str()` is the reason phrase. Reading it is NOT free: an unbounded `read()` on the
    error path is subject to the same per-recv timeout reset the 200 path documents, so
    `_body_names_rate_limit` reads it in DEADLINE-CHECKED chunks — see that function for the bound
    and for the one path it does not cover.

    ⛔ AND THE r10 REPLACEMENT FOR THAT SENTENCE ALSO WENT STALE, WHICH IS THE POINT OF SAYING IT
    (#2138 r13). It read "the error path has no chunk loop, so a bounded read here is one
    `read(ERR_BODY_BYTES)` under the socket's own timeout … ONCE and CAPPED". All three clauses
    are false of the code that replaced it: there IS a chunk loop, the read is
    `_read(min(ERR_BODY_CHUNK, …))` with `ERR_BODY_CHUNK = 512` i.e. up to 8 calls, and it prefers
    `read1()`, so the socket's own timeout is not what bounds it either. Left standing, this
    paragraph was an invitation to "simplify" the loop back to a single `read()` — reinstating the
    unbounded stall the loop exists to prevent.

    The KIND is therefore decided from evidence, strongest first:
      * a 429 is GitHub's rate-limit status;
      * the error body NAMING the rate limit (the exact sentence GitHub sends);
      * on a 403/429 only, `x-ratelimit-remaining: 0` or a `retry-after`;
      * otherwise only the status is named, so the claim stays UNREADABLE rather than inventing a
        limit GitHub never reported.
    ⛔ `retry-after` IS GATED ON 403/429 ON PURPOSE (#2138 r10, reviewer A residual). RFC 7231
    pairs it with 503 as well, so an edge emitting `Retry-After` on an ordinary outage would
    otherwise turn `VERDICT` into GH-RATE-LIMITED and tell the fleet to wait out a limit that
    never existed. Under-classifying is the safe direction; over-classifying is not.
    """
    def _h(name):
        try:
            return (e.headers.get(name) or "").strip().lower()
        except Exception:
            return ""
    limit_status = e.code in (403, 429)
    why = []
    if e.code == 429:
        why.append("429 is GitHub's rate-limit status")
    if _body_names_rate_limit(e, deadline):
        why.append("the response body names the rate limit")
    if limit_status:
        if _h("x-ratelimit-remaining") == "0":
            why.append("x-ratelimit-remaining=0")
        if _h("retry-after"):
            why.append("retry-after=" + _h("retry-after"))
    head = "HTTP %s%s" % (e.code, " " + str(e.reason) if getattr(e, "reason", None) else "")
    return "%s (rate limit exceeded: %s)" % (head, "; ".join(why)) if why else head


ERR_BODY_BYTES = 4096
ERR_BODY_CHUNK = 512


def _body_names_rate_limit(e, deadline=None):
    """A CAPPED, DEADLINE-CHECKED read of the error body, purely to name the cause.

    GitHub's 403/429 body carries the sentence that settles the question ("API rate limit exceeded
    for user ID …"), which is stronger evidence than any header.

    ⛔ ONE `read(n)` IS **NOT** BOUNDED BY `timeout=` (#2138 r11). `timeout` reaches the socket as
    a PER-RECV timeout, so `read(4096)` loops over recvs and every one resets it: measured, a 403
    trickling one byte per millisecond returned from a single `read(4096)` after **4.79 s against
    `timeout=0.5`** — 9.6x the timeout and 9.6x the page budget. That is the same mechanism this
    file already records for the 200 path, and the earlier version of this helper asserted the
    opposite for the error path. At `QUEUE_REST_TIMEOUT_S = 30` the worst case would be 4096 x 30 s,
    i.e. a stall past `run_bounded 90 objective-refresh`, where the beat is killed with NO line
    written — the silent stall the chunk loop exists to prevent.

    So: `read1()` where it exists, `deadline` checked BEFORE every chunk, and `ERR_BODY_BYTES` as
    the cap.

    ⛔ WHAT THAT ACTUALLY BUYS, STATED EXACTLY (#2138 r12, reviewer — the r11 wording here was
    wrong three times over). `read1()` is one recv per call ONLY for a `Content-Length` body, where
    it reduces to a plain read; for a CHUNKED body it routes through `_read1_chunked` ->
    `_get_chunk_left` -> `readline()`, which loops recvs (measured 2.45 s against a 0.5 s
    deadline), and if `read1` is absent the `e.read` fallback is `read(512)`, i.e. up to 512 recvs
    (measured 5.19 s). So the operative bound is the CALLER'S DEADLINE, checked between chunks,
    plus at most one chunk's worth of trickle — and with NO deadline supplied, the 4096-byte cap is
    the only bound at all (measured 6.33 s against `timeout=0.5`). The one production caller always
    passes the read's page deadline, which is what makes the deadline the bound that holds.

    ⛔ AND THIS IS THE SAME SEAM THE 200 PATH USES, WITH THE SAME `read1` PREFERENCE (#2138 r12,
    r14). That path USED to read `r.read(8192)` with no `read1` at all, so a single call could
    spend up to 8192 recvs before the deadline was next consulted — the exact defect this helper
    was written for, measured at 4.63 s against a 0.5 s budget. r14 closed it the same way here:
    both paths now take `read1` where the response offers it, so one call is one recv and the
    deadline — checked between calls — is the operative bound. The accurate phrasing for both is
    the one used at `_queue_rest`: "a BODY costs at most one RECV past the budget".

    ⛔ RESIDUAL — THE CHUNKED FRAMING PHASE IS INSIDE ONE `_read` AND OUTSIDE BOTH BOUNDS (#2138
    r13, measured). For a CHUNKED body, `read1` reaches `_read_next_chunk_size()`, which is
    `self.fp.readline(_MAXLINE + 1)` with `_MAXLINE = 65536`, and the last chunk is followed by
    `_read_and_discard_trailer()`, which loops that readline with NO limit. Both run inside a
    SINGLE `_read` call — the deadline is checked only BETWEEN calls, and framing bytes are never
    appended to `raw`, so `ERR_BODY_BYTES` does not count them either. Measured: a 403 whose
    chunk-extension trickled returned after 3.23 s against a 0.20 s deadline (1501 framing bytes
    in that one call), and with `deadline=None` the trailer read alone took 3.82 s over 6001 bytes
    — more than the cap. So "one chunk past the budget" is true of the BODY and not of the
    FRAMING. GitHub's error bodies carry `Content-Length` (measured), which takes the non-chunked
    path this paragraph does bound; closing the chunked case means not using urllib's chunk reader,
    which is a change to how this function talks to the socket, not a budget tweak.

    ⛔ AND IT NEVER RAISES, WHICH MEANS THE WHOLE BODY IS INSIDE THE `try` (#2138 r11). With the
    comparison outside it, a non-bytes body raised `TypeError` out of `_rest_refusal_text` and out
    of `_rest_get`'s `except` arm, which classified it as a TRANSPORT failure and threw the
    refusal's kind away. What stops that is `raw += chunk`: `raw` starts as `b""` and only ever
    accumulates, so a `str` body raises `TypeError: can't concat str to bytes` AT THE
    CONCATENATION — inside the `try`, which is the property that matters. `bytes(raw)` is a
    no-op belt on an already-bytes value (the r11 note credited it with the protection; it does
    not provide it).
    """
    raw = b""
    try:
        _read = getattr(e, "read1", None) or e.read
        while len(raw) < ERR_BODY_BYTES:
            if deadline is not None and _monotonic() > deadline:
                break
            chunk = _read(min(ERR_BODY_CHUNK, ERR_BODY_BYTES - len(raw))) or b""
            if not chunk:
                break
            raw += chunk
        return b"rate limit" in bytes(raw).lower()
    except Exception:
        return False


def _rest_get(url, token, timeout=QUEUE_REST_TIMEOUT_S, deadline=None):
    """One REST GET, behind ONE seam so the fallback is provable without a network.

    Returns the decoded body and RAISES on any failure; the caller treats every raise as "no
    second source". The token is only ever placed in the header -- it must never reach a log
    line, an exception message of ours, or `GH_LAST_ERROR`.

    ⛔ `urllib` IS IMPORTED HERE, NOT AT MODULE SCOPE. It pulls in `http.client` and `ssl`; on a
    python built without OpenSSL a top-level import would kill the WHOLE farmed script at start
    (`STALL objective-refresh`, no line, no cache) instead of degrading one read to "no second
    source" through this function's own failure path.

    ⛔ REDIRECTS ARE REFUSED. urllib's default handler follows a 30x and REBUILDS the request with
    the caller's headers -- including `Authorization` -- for whatever host the 30x names, which
    would hand a full-scope token to a third party. `redirect_request` returning None turns a 30x
    into an `HTTPError`, i.e. into "no second source", which is the honest answer here.

    ⛔ AND THE BODY IS READ IN CHUNKS AGAINST THE CLOCK, NOT IN ONE `read()` (#2138 r2, A).
    `timeout=` reaches the socket as a PER-RECV timeout, so a peer that trickles bytes keeps
    resetting it: a single `r.read()` against a byte-at-a-time server returned a complete page
    after **14.9 s with `timeout=0.5`** (measured in review, 29.7x the timeout). So the body is
    read against the clock in bounded pieces and the deadline is re-checked BEFORE each one.

    ⛔ THE PIECE MUST BE ONE RECV, NOT ONE `read(n)` (#2138 r14, reviewer — the r2 fix was
    INCOMPLETE and this docstring described the bound it did not have). The r2 loop checked the
    deadline between calls but called `r.read(8192)`, and on CPython that is
    `BufferedReader.read(n)` -> up to **n `recv`s**, each resetting the socket's per-recv timeout.
    The deadline cannot fire INSIDE a call, so the worst case was 8192 x `QUEUE_REST_TIMEOUT_S`,
    i.e. a stall past `run_bounded 90 objective-refresh` — and a killed beat writes NO line, which
    is strictly worse than the refusal this fallback replaces. "At most one chunk" is a bound on
    BYTES, not on TIME; stated as one chunk it was false. So: `read1` where the response offers it
    (one recv per call, and `HTTPResponse.read1` exists on every CPython this repo runs), the
    `read` fallback otherwise, and the deadline checked before each call. The overrun is now at
    most ONE RECV, pinned by
    `test_one_read_call_is_one_recv_so_the_DEADLINE_bounds_the_page`, whose fake response spends
    one clock tick per recv: on the pre-r14 `read(8192)` it overshoots a 1 s budget by 7.2 s and
    the pin fails.

    ⛔ THE PHASE THIS DOES NOT COVER IS `open()` ITSELF (#2138 r5, A/P3): the status line and the
    headers are read under the socket timeout, before this loop gets control, so a HEADER trickle
    can exceed the budget by the header phase — bounded only by the per-recv timeout, not by the
    deadline. That residual is STATED rather than patched with a second check: a post-`open()`
    deadline test would be redundant, because the first thing this loop does is the same check
    before any body byte is read (so a late response never contributes a chunk). What the bound
    therefore buys is: every page's BODY is read against the clock, retries and backoff fit inside
    the read's cap, and a page that arrives late is discarded — with one header phase, priced in
    the socket timeout, outside it.
    """
    import urllib.error
    import urllib.request

    class _NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None

    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "objective.py (agent-infra heartbeat)",
    })
    try:
        r = urllib.request.build_opener(_NoRedirect).open(req, timeout=timeout)
    except urllib.error.HTTPError as e:
        # ⛔ RE-RAISED WITH THE STATUS NAMED (#2138 r9, both reviewers). Left alone, an `HTTPError`
        # is an `OSError` whose text is "HTTP Error 403: Forbidden" — no marker, no claim, no
        # attribution. Re-raising as the SAME TYPE keeps `.code`/`.headers` for any caller that
        # inspects them (the redirect guard's own test asserts the type), while the rewritten text
        # states the code and any limit evidence, so the transport/parse classifier is unchanged
        # and the marker gate can actually see a 4xx/5xx.
        _text = _rest_refusal_text(e, deadline)
        # ⛔ FORWARD `e.fp`, NOT `e` (#2138 r11 corrects r10 here). Forward the underlying file
        # object: passing the exception would hand the new error a reader that delegates back into
        # an error. And on every interpreter this repo runs (3.10+), `HTTPError.__init__`
        # substitutes an empty `BytesIO` when `fp` is None and THEN runs the base init
        # unconditionally, so `.read()` always exists and returns b"" for a bodiless error.
        # (r10 claimed the base init was SKIPPED when `fp is None`. That was true only up to 3.9
        # and is false here; the code was harmless, the stated reason was not.)
        raise urllib.error.HTTPError(e.url, e.code, _text, e.headers,
                                     getattr(e, "fp", None)) from e
    with r:
        chunks = []
        # ⛔ ONE CALL MUST BE ONE RECV (#2138 r14). Same seam as `_body_names_rate_limit`: without
        # it `read(8192)` can loop over 8192 recvs, each resetting the socket timeout, and the
        # deadline below is only consulted BETWEEN calls — so it cannot bound a single one.
        _read = getattr(r, "read1", None) or r.read
        while True:
            if deadline is not None and _monotonic() > deadline:
                # Raise rather than return: the caller's single failure path already treats a
                # raise as "no second source", and a partial body is not a page.
                raise TimeoutError("response body overran the page budget while arriving")
            chunk = _read(8192)
            if not chunk:
                break
            chunks.append(chunk)
        return json.loads(b"".join(chunks).decode("utf-8"))


def _rest_pr(p):
    """One REST pull -> the `gh pr list --json` shape the rest of this file consumes.

    ⛔ THE LIST ENDPOINT CARRIES **NO MERGEABILITY AT ALL** (#2138 r5, A/P2 — MEASURED, and it
    overturns an earlier assumption in this very file). `GET /repos/<R>/pulls?state=open` returns
    neither `mergeable` nor `mergeable_state`: on 3 open PRs of two repos the response had 0/3 rows
    with either key, and the file itself already recorded the pre-existing version of this fact
    ("the REST list endpoint returns null here and is no better"). So the keys are mapped **only if
    a payload has them** -- a per-PR `GET /pulls/<n>` would, and that is the follow-up -- and a
    LIST-sourced row is ALWAYS unread for the merge state:

      * `mergeStateStatus` is `None` for every row (`_mergeable_unknown()` counts it as unread);
      * `mergeable` is `"UNKNOWN"` for every row;
      * therefore a REST pass prints `queue_read=REST(merge_state unread N/N …)` and its CLASS
        counts are never a clearance;
      * and `classify_pr()`'s `DIRTY` arm CANNOT fire on a REST pass. An earlier revision of this
        function inferred `DIRTY` from `mergeable: false` -- dead code against the real endpoint,
        and a false claim that `resolve-conflict` was reachable over REST. It is removed rather
        than kept as decoration: a fix that cannot run is worse than a recorded gap.

    ⛔ `files: []` MEANS *UNKNOWN*, NEVER "EMPTY DIFF". The list endpoint carries no file list
    (that is one call per PR), so `touches_surface()` reads `[]` and answers False on a
    REST-recovered pass. The overlay is then NOT READ, and `build()` SAYS SO instead of omitting
    the token -- `ASK-USER: surface=UNREAD(rest list carries no file list)` -- because a residual
    that never reaches the printed line is a false absence (three reviewers, one shape). Closing it
    needs one `/pulls/<n>/files` call per PR, which changes this `files: []` contract.

    The same one-call-per-PR shape would close the merge-state gap (`/pulls/<n>` DOES carry
    `mergeable`); that is a dispatch-precision change with its own cost, filed on #2138 rather than
    smuggled into the resilience read.
    """
    m = p.get("mergeable")
    state = (p.get("mergeable_state") or "").upper() or None
    return {
        "number": p.get("number"),
        "isDraft": bool(p.get("draft")),
        "mergeable": ("MERGEABLE" if m is True else
                      "CONFLICTING" if m is False else "UNKNOWN"),
        "mergeStateStatus": state,
        "headRefOid": ((p.get("head") or {}).get("sha") or ""),
        "files": [],
    }


def _queue_rest(deadline=None):
    """The open PR list over REST, or None on ANY failure -- never an empty queue.

    ⛔ `[]` IS NEVER A FAILURE VALUE HERE. It is the honest answer for a repo with no open PRs,
    which is why every failure returns None instead. The CALLER records the failure BEFORE it
    calls this (see `queue()`), so `queue=UNREADABLE` prints and the RATE-LIMITED verdict still
    outranks the queue; when this returns None the caller raises and its `except` re-notes the
    COMBINED cause (primary + this one). The surface is only ever added to `GH_BLOCKED_BY` once, so
    the second note is a text update, not a second claim. A degraded read rendered as `waiting=0`
    would read AT-TARGET -- the one wrong answer this instrument can give.

    ⛔ A NON-LIST BODY IS A FAILURE, NOT ZERO PRs. A dict here is an error/notice body, and a
    non-dict element inside a list is a payload we do not understand; either way the whole pass
    is unread. Silently keeping the dicts we recognise would publish a LOWER BOUND as if it were
    the queue depth (the under-count direction that reads as AT-TARGET).

    ⛔ `deadline` IS A WALL-CLOCK BUDGET, NOT A SUGGESTION (`_monotonic()` seconds, the same
    clock `queue()` uses). Every page's timeout is clipped to what is LEFT of it, and a spent
    budget is a FAILED read -- never a shorter page, and never a wait past it. Without this the
    fallback could spend `MAX_PAGES x TIMEOUT_S` inside a loop the beat kills at 90 s, and a
    killed refresh writes NO line at all: the recovery would be strictly worse than the refusal
    it replaces.

    ⛔ HONEST BOUND, MEASURED RATHER THAN ASSUMED (#2138 r2, A). A socket timeout is a PER-RECV
    timeout, so it does NOT bound a page: a peer trickling bytes resets it on every read (`_rest_get`
    read a complete page in 14.9 s with `timeout=0.5`). The page's BODY is therefore bounded by the
    CHUNK LOOP inside `_rest_get` -- which re-checks this budget before each RECV -- and by
    the AFTER-THE-PAGE check below, which discards a page that arrived late. That much holds: a BODY
    costs at most one RECV past the budget (#2138 r14 -- it said "one chunk", which was true of
    bytes and false of time until the loop took `read1`).

    ⛔ AND THAT IS NOT THE WHOLE PAGE, WHICH IS WHY THIS PARAGRAPH NO LONGER PRETENDS IT IS (#2138
    r9, reviewer B). `open()`'s STATUS LINE AND HEADERS are read under the socket timeout, BEFORE
    the chunk loop gets control -- `_rest_get` states this itself -- so a header trickle overruns by
    the HEADER phase, which is bounded only by the per-recv timeout and NOT by this budget. This
    paragraph previously concluded "the fallback is never the reason a refresh misses its 90 s
    kill"; that is not true as written, and this file's own
    `test_a_response_that_arrives_past_the_budget_contributes_NO_chunk` demonstrates a page whose
    `open()` alone spends 60 s against a 10 s budget. The arithmetic in `QUEUE_READ_MAX_S`
    (12 + 45 + 12 against the 90 s kill) leaves ~21 s of headroom, which is LESS than one 30 s
    header phase -- so a header stall can carry the tick past the kill, where NO line prints.
    Stated rather than papered over: closing it needs a bound on the header phase (a shorter
    per-recv timeout, or a watchdog around `open()`), which is a change to `_rest_get`'s socket
    handling and not to this budget.

    PAGING: one page is 100. A deeper queue is read a page at a time; a SHORT page is the end. A
    FAILED page discards the whole read, and so does REACHING THE CAP WITH A FULL PAGE -- both are
    "this is not the queue", and a truncated list printed as the depth is an under-count (ten
    PRs of a 500+ backlog would read `waiting` as the whole queue).
    """
    global GH_LAST_ERROR, _REST_TRANSPORT
    # ⛔ EVERY EXPLICIT `return None` BELOW IS A BODY/CONFIG FAILURE, NOT A TRANSPORT ONE
    # (#2138 r7, reviewer B). GitHub ANSWERED with something unusable, or we refused to open a
    # socket. The one classifying site is the `_rest_get` call, and it classifies by WHAT failed,
    # not by where the exception was raised (#2138 r8 — see the note there). `queue()` ORs this
    # with the primary's own flag, so the composite refusal is a transport failure if EITHER
    # source hit one: a primary we mangled plus a fallback GitHub REFUSED is still blindness, and
    # losing that claim degraded the verdict to `UNKNOWN` where the reader needed "wait for the
    # limit".
    _REST_TRANSPORT = False
    token = _gh_token()
    if not token:
        GH_LAST_ERROR = (f"rest second source: no credential (GH_TOKEN/GITHUB_TOKEN unset and no "
                         f"github.com oauth_token in {_gh_hosts_path()})")
        return None
    rows = []
    try:
        for page in range(1, QUEUE_REST_MAX_PAGES + 1):
            budget = QUEUE_REST_TIMEOUT_S
            if deadline is not None:
                budget = min(budget, deadline - _monotonic())
                if budget < 1.0:
                    GH_LAST_ERROR = (f"rest second source: page {page}: the queue read's own budget "
                                     "was spent before the fallback could fetch it")
                    return None
            # ⛔ THE `_rest_get` CALL IS THE ONE CLASSIFYING SITE (#2138 r7, reviewer B), because the
            # broad `except` below also catches a `_rest_pr` MAPPING error -- a body we did not
            # understand, not a failure to reach GitHub.
            try:
                body = _rest_get(
                    f"https://api.github.com/repos/{REPO}/pulls"
                    f"?state=open&per_page={QUEUE_REST_PAGE}&page={page}", token,
                    timeout=budget, deadline=_monotonic() + budget)
            except Exception as e:
                # The URL is safe to name; the token never is.
                GH_LAST_ERROR = f"rest second source failed: {type(e).__name__}: {str(e)[:180]}"
                # ⛔ CLASSIFIED BY WHAT FAILED, NOT BY WHERE IT WAS RAISED (#2138 r8, both reviewers).
                # `_rest_get` ends in `json.loads(...)`, so a 200 carrying HTML or non-UTF-8 raises
                # FROM INSIDE IT -- and GitHub ANSWERED, which is a PARSE failure by this file's
                # own contract. Treating "raised by `_rest_get`" as "the transport" made a
                # decode-failing fallback a transport failure, and because the composite cause
                # text CONCATENATES both halves, the PRIMARY's mangled body could then supply the
                # `TRANSPORT_MARKERS` hit: two reads that both reached GitHub published
                # `gh=UNREADABLE(queue)` / `VERDICT=GH-RATE-LIMITED`. Measured. A decode failure is
                # the parser's fact, not the network's.
                _REST_TRANSPORT = not isinstance(e, (json.JSONDecodeError, UnicodeDecodeError))
                return None
            if not isinstance(body, list):
                GH_LAST_ERROR = (f"rest second source returned {type(body).__name__}, not a list")
                return None
            if not all(isinstance(p, dict) for p in body):
                GH_LAST_ERROR = "rest second source returned a non-object element in the PR list"
                return None
            rows.extend(body)
            if deadline is not None and _monotonic() > deadline:
                # The page ARRIVED, but past the budget: a stale answer is not a measurement. (A
                # socket timeout bounds each recv, not the page -- `_rest_get`'s chunk loop is the
                # real per-page bound; this is the belt after it, see the honest-bound note above.)
                GH_LAST_ERROR = "rest second source: budget overrun during page %d" % page
                return None
            if len(body) < QUEUE_REST_PAGE:
                break
        else:
            # The loop exhausted its pages WITHOUT a short one: the cap was reached on a FULL page.
            # This is the truncation branch -- it must not fall through to `return` below.
            GH_LAST_ERROR = (f"rest second source: {QUEUE_REST_MAX_PAGES} full pages "
                             f"({len(rows)} open PRs) is the cap, not the queue")
            return None
        # ⛔ THE MAPPING IS INSIDE THE `try` (#2138 r3, A). It used to sit after the `except`, so a
        # row that passed the shape checks but broke `_rest_pr()` (e.g. `head` as a string) raised
        # a bare `AttributeError` out of this function -- and `queue()`'s own classifier does not
        # call that a transport failure, so the line printed `queue=UNREADABLE` with NO `gh=` claim:
        # the unattributed blindness this file's docstring forbids. Here it is one more "no second
        # source" with a named cause.
        return [_rest_pr(p) for p in rows]
    except Exception as e:
        # The URL is safe to name; the token never is.
        GH_LAST_ERROR = f"rest second source failed: {type(e).__name__}: {str(e)[:180]}"
        return None


def _withdraw_gh_failure(surface):
    """A SECOND SOURCE answered, so the claim the first one recorded is no longer true.

    Mirrors `main_health()`'s own withdrawal: only the surface in question gives up its claim, so
    a queue recovered over REST cannot un-blind a main that is still refused (and vice versa).
    Without this, a recovered read would still print `gh=RATE-LIMITED(queue)` AND rewrite the
    verdict to `GH-RATE-LIMITED` -- the fallback would succeed and the line would still say the
    fleet is blind.

    ⛔ THE BUCKET AND THE CAUSE GO WITH THE CLAIM (#2138 r2, two reviewers). Removing the SURFACE
    alone left its KIND behind, so a retracted RATE-LIMITED could be republished as the kind of
    the surface that was still failing (measured shape: main `HTTP 504` + a queue refusal REST
    recovered -> `gh=RATE-LIMITED(main)`, and the verdict rewritten to wait for a limit main
    never hit). `GH_LAST_ERROR` is cleared only when it still IS this claim's text, so a fresh
    unrelated error from another read is never erased.
    """
    global GH_BLOCKED, GH_LAST_ERROR
    withdrawn_text = GH_CLAIM_TEXT.pop(surface, "")
    GH_CLAIM_KIND.pop(surface, None)
    GH_BLOCKED_BY[:] = [s for s in GH_BLOCKED_BY if s != surface]
    GH_BLOCKED = _recompute_gh_blocked()
    if withdrawn_text and GH_LAST_ERROR == withdrawn_text:
        GH_LAST_ERROR = GH_CLAIM_TEXT.get(GH_BLOCKED_BY[-1], "") if GH_BLOCKED_BY else ""


def _mergeable_unknown(ms):
    """How many non-draft PRs came back with an UNREAD lazy merge state (`ms` = Counter)."""
    return sum(c for k, c in ms.items() if k not in KNOWN_MERGE_STATES)


def _queue_read_is_blind(unknown, nondraft, source="graphql"):
    """True iff the lazily-computed merge state is unread for MOST of the queue.

    ⛔ A REST-SOURCED SAMPLE IS NEVER BLIND (#2138), and this is a decided behaviour, not an
    oversight. `BLIND` is this file's word for "the QUEUE read did not answer"; a REST sample
    DID answer -- the list, its length and every row are real. What REST cannot answer is the
    LAZY merge state (`mergeable_state` is frequently "" while GitHub computes it), and that
    is a different, narrower fact: the queue DEPTH is read, the CLASS counts are not. So a REST
    sample reports its unread count instead of borrowing the blindness word, and it is not
    re-sampled either -- re-reading a field REST does not compute would only spend the beat's
    90 s budget to learn the same thing.

    The read WAS blind in the other direction (GraphQL said UNKNOWN for the whole queue) -- that
    is the case the re-sample exists for, and it is unchanged.

    THE ONE DEFINITION, shared by the re-sample that tries to settle the read and by the
    report that finally declares it blind -- so the retry can never stop on a queue the line
    then calls readable, or keep re-reading a queue it is about to call blind. A read is blind
    when ANY PR is unread and at least half of them are: one unread PR in a 20-PR queue does
    not invalidate the DO list, and an unread queue of one does.

    ⛔ THIS IS THE *READ* QUESTION, NOT THE *CLEARANCE* QUESTION (#1942 review, A/P2).
    `pr-loop.py` ACTS, so what it needs is `_class_counts_are_a_clearance()` below -- which
    answers this one for a GraphQL read and DELEGATES here, so a re-threshold still moves the
    dispatcher instead of orphaning it. Neither function is a second copy of the other.

    The predicate itself is UNCHANGED from the pre-#1869 report (`_u > 0 and
    2 * _u >= max(1, nondraft)`). What changed is that the read is now SAMPLED AGAIN before
    that verdict is given, instead of being declared blind on the first sample.
    """
    if source == "rest":
        return False
    return unknown > 0 and 2 * unknown >= max(1, nondraft)


def _class_counts_are_a_clearance(unknown, nondraft, source="graphql"):
    """True iff the per-CLASS counts may be ACTED on -- the question `pr-loop.py` asks.

    ⛔ TWO QUESTIONS, AND #1918 IS ABOUT THE SECOND ONE (#1942 review, A/P2).
    `_queue_read_is_blind()` answers "did the QUEUE read answer?", and a REST sample answers
    it YES -- the list, its length and every row are real (#2138). But the CLASSES are built
    from the LAZY merge state, and a class is exactly what the dispatcher acts on. A REST pass
    leaves `mergeStateStatus` None for EVERY row (`_rest_pr`), so `unknown == nondraft` there:
    the depth is read, the classes rest on a field GitHub never computed. That is not a
    property of the COUNT, so it cannot be expressed by the majority threshold -- the beat
    itself prints it per source ("GitHub did not compute the merge state, so the CLASS counts
    are NOT a clearance"), and this function is that sentence, callable.

    ⛔ WHY NOT "HOLD WHENEVER `unknown > 0`" FOR EVERY SOURCE. On the GraphQL path one unread
    PR in a deep queue is ordinary churn -- the majority threshold above exists precisely so
    that does not stop the dispatch, and collapsing the two questions would make ANY mid-
    recompute row hold the whole fleet. The REST case is not a matter of degree: EVERY row is
    unread, so it is qualified on its PROVENANCE, not on a count.

    ⛔ AND WHY THE DISPATCHER MAY HOLD WHERE THE REPORT DOES NOT SAY `BLIND`. The report's
    vocabulary is the qualifier, not the verdict: for REST it prints "the CLASS counts are NOT
    a clearance" instead of the word BLIND, and the dispatcher obeying that sentence is the
    two-answers drift being CLOSED, not opened. Saying BLIND about a REST read would be a lie
    about what was read; acting on it anyway is the lie that costs lanes.
    """
    if source == "rest":
        return not unknown
    return not _queue_read_is_blind(unknown, nondraft, source)


def queue():
    """The open PR queue, re-sampled while its LAZY merge state is unread (see above).

    Two SOURCES, one answer: `gh pr list` (GraphQL) first, and REST only when that read FAILS
    (#2138). The fallback is not a retry and not a second opinion -- it is the other bucket, so
    a queue that GitHub refuses to answer over GraphQL is still reported instead of
    `queue=UNREADABLE`. A REST-sourced sample carries its own provenance, because REST cannot
    compute the lazy merge state and must not be read as a blind GraphQL read (nor as a
    readable one).
    """
    # ⛔ THE HEAVIEST READ MUST GO THROUGH THE LAYER TOO. `gh pr list` is GraphQL and this is the
    # beat's largest read; a bare `"gh"` here resolved on PATH — unserialised, un-backed-off, and
    # subject to the #1872 shim — while every other **gh-CLI** read in this file uses GH_BIN (found
    # in review round 5).
    # ⛔ "gh-CLI" IS THE QUALIFIER THAT KEEPS THIS TRUE (#2138 r6, A/P2 + reviewer E). The REST
    # second source below does NOT go through GH_BIN or the layer: `_queue_rest` -> `_rest_get` is
    # a raw `urllib` GET. That is a DELIBERATE, PRICED departure and it is stated here rather than
    # left for a reader to discover by grepping:
    #   * COST — it is UNSERIALISED (no `gh-limit` flock queue), does no `retry-after`/
    #     `x-ratelimit-reset` back-off, and keeps no ETag, so a 304 costs a full body. It fires
    #     exactly when the shared account is being refused, i.e. potentially on every lane at once.
    #   * WHY THE LAYER CANNOT SERVE IT — the layer routes `gh` INVOCATIONS, and the queue's own
    #     `gh()` helper hardcodes `timeout=90` with no deadline, which cannot fit
    #     `QUEUE_READ_MAX_S`; reusing it would make the fallback unable to answer inside the tick
    #     it exists for. Reading the token file directly also avoids a second `gh` process on the
    #     hot path of the read that exists BECAUSE the subprocess path was refused (#1872).
    #   * BOUND — one page's worth per read, capped by `_queue_rest`'s page count and the read's
    #     deadline, and never re-sampled. The residual (no serialisation) is accepted and named.
    argv = [GH_BIN, "pr", "list", "--repo", REPO, "--state", "open",
            "--limit", str(QUEUE_PRIMARY_LIMIT), "--json",
            "number,isDraft,mergeable,mergeStateStatus,headRefOid,files"]
    sample = None
    reads = 0
    resample_failed = 0
    read_start = _monotonic()
    read_deadline = read_start + QUEUE_READ_MAX_S   # the cap the WHOLE read answers to (see above)
    deadline = read_start + QUEUE_BLIND_BUDGET_S    # measured from the FIRST read
    for attempt in range(QUEUE_BLIND_ATTEMPTS):
        remaining = deadline - _monotonic()
        if attempt and remaining <= 0:
            break          # the beat's budget for re-reading is spent: BLIND is then truthful
        # ⛔ A RE-SAMPLE MUST NOT NEST A SECOND RETRY POLICY. The FIRST read keeps `_gh_retry`'s
        # transport resilience (the whole tick depends on it), but a re-read is a retry ALREADY:
        # `attempts=1` with the REMAINING budget as its timeout is what makes the wall-clock
        # bound real -- otherwise the worst case is 4 samples x 3 transport attempts x its own
        # 120 s timeout, which is a kill, and a killed refresh writes NO line at all.
        # ⛔ AND A TIMEOUT RAISES -- it does not return `returncode != 0`. `subprocess.run(...)`
        # raises `TimeoutExpired`, which is exactly the failure the short re-read timeout makes
        # most likely. Uncaught, it escapes `queue()`, `build()` and the held sample with it, and
        # every count, the DO list and the BLIND token are replaced by a bare `error=` line --
        # strictly worse than not re-reading. So the call AND the payload derivation are inside
        # the same absorb-and-keep-sample path as a failed transport.
        surface = "queue" if not attempt else "queue-resample"
        source = "graphql"
        # ⛔ THE CALLER STATES THE TRANSPORT, IT DOES NOT LEAVE `_note_gh_failure` TO GUESS
        # (#2138 r6, A/P1). The contract at `_note_gh_failure`'s module comment says a non-zero
        # exit IS the transport and an UNPARSEABLE BODY IS NOT, and that the caller therefore
        # states it in `transport=` "rather than leaving this function to guess from the text".
        # This call site passed a constant `True` for BOTH cases, so the only thing keeping a
        # parse failure out of the blindness claim was `TRANSPORT_MARKERS` -- i.e. the guess the
        # contract forbids. MEASURED: an rc=0 body reading `{"message": "read timed out"}` (not
        # JSON, therefore not a queue) published `gh=UNREADABLE(queue)` while GitHub had ANSWERED.
        primary_transport = True      # a read that failed without reaching GitHub
        refusal_transport = None      # set only where WE synthesise the both-sources refusal
        try:
            if not attempt:
                # ⛔ THE PRIMARY READ ANSWERS TO THE READ'S OWN CAP, RETRIES INCLUDED (#2138 r4, A).
                # `_gh_retry(argv)` with its defaults is 3 attempts x a 120 s timeout, so the ONE
                # read the trick depends on was the only unbounded thing in the tick. The budget
                # is threaded in so the retry policy fits inside it.
                #
                # ⛔ AND A TIMEOUT RAISES -- it does not return `returncode != 0`. `subprocess.run`
                # raises `TimeoutExpired`, which is exactly the failure the bound makes most
                # likely, so a raise is folded into the SAME "the primary read failed" path: it
                # records the claim, tries the second source, and only raises when both refuse.
                # Leaving it to the outer `except` made the fallback inert in one whole class of
                # primary failure -- the class it exists for -- printing `queue=UNREADABLE` while
                # REST was healthy (review round 4, A).
                try:
                    r = _gh_retry(argv, deadline=read_deadline)
                    primary_failed = r.returncode != 0
                    _graphql_err = ((r.stdout or "") + (r.stderr or "")).strip()
                except Exception as _exc:
                    r, primary_failed = None, True
                    _graphql_err = f"{type(_exc).__name__}: {_exc}"
                if not primary_failed:
                    # ⛔ A PAYLOAD WE CANNOT USE IS A FAILED READ, NOT A DEAD END (#2138 r5, A/P2).
                    # rc=0 with unusable JSON used to raise into the outer `except`, which classes
                    # it as NON-transport -- so no surface claimed blindness and the line printed an
                    # UNATTRIBUTED `queue=UNREADABLE` while a healthy second source was never
                    # consulted (the asymmetry the REST side already fixed in r3). It also slipped
                    # the cache guard, which keys on the `gh=UNREADABLE` token, so the beat SERVED
                    # that blind line for up to 120 s. Same path, same cause, same fallback.
                    #
                    # ⛔ AND `--limit 400` TRUNCATES SILENTLY (#2138 r5, A/P3): the identical
                    # under-count shape the REST side REFUSES at its cap. A depth published from a
                    # full page is a lower bound printed as the queue, so it is a failed read too
                    # (recoverable over REST, whose cap is 5 x 100).
                    #
                    # ⛔ AND THE ROW SHAPE IS PART OF "A PAYLOAD WE CAN USE" (#2138 r11, P3).
                    # `json.loads` succeeding is not the same as the rows being PRs: the
                    # classifier below reads `p["isDraft"]` OUTSIDE this validated block, so a
                    # list of non-objects (or of objects without `isDraft`) raised a bare
                    # `TypeError`/`KeyError` into the outer `except` -- where no surface is named
                    # (`transport=False` on a parse failure) and, because `primary_failed` stayed
                    # `False`, the second source was NEVER TRIED. Exactly the dead end the
                    # paragraph above exists to close, and exactly the shape the REST side
                    # already guards (`_queue_rest` refuses a non-object row rather than
                    # shortening the queue). Checked here so a payload we cannot CLASSIFY is a
                    # failed read with the same fallback and the same attribution as any other.
                    try:
                        prs = json.loads(r.stdout)
                        if not isinstance(prs, list):
                            raise ValueError(f"payload is not a list: {str(prs)[:120]}")
                        if not all(isinstance(p, dict) and "isDraft" in p for p in prs):
                            raise ValueError("payload rows are not PR objects: "
                                             f"{str(prs)[:120]}")
                        if len(prs) >= QUEUE_PRIMARY_LIMIT:
                            raise ValueError(f"{len(prs)} open PRs is the primary read's cap, "
                                             f"not the queue")
                    except Exception as _exc:
                        primary_failed = True
                        # GitHub ANSWERED and we could not read the answer: not blindness. This
                        # is the fact the comments below and at the outer `except` already
                        # claim; it is now carried rather than inferred from the message.
                        primary_transport = False
                        _graphql_err = (str(_exc) if isinstance(_exc, ValueError)
                                        else f"{type(_exc).__name__}: {_exc}")
                if primary_failed:
                    # ⛔ THE SECOND SOURCE, TRIED ONLY FOR THE PRIMARY READ (#2138 r4, A). A
                    # RE-SAMPLE's refusal must NOT come here: the list was already read, so
                    # re-reading it over REST would (a) misstate the provenance (`the GraphQL read
                    # was refused` on a tick whose first read ANSWERED) and (b) contradict
                    # `_queue_read_is_blind()`'s rule that a REST sample is not re-sampled. A
                    # re-sample that fails keeps the sample it already holds, below.
                    #
                    # A non-zero exit is in practice a REFUSAL (the secondary limit), which is
                    # what the incident and its tests are about; any other non-zero (e.g. a future
                    # argv/field error gh answers with rc=1) also lands here, so the second source
                    # would mask such a drift. Stated rather than hidden, AND GUARDED:
                    # `test_the_graphql_field_list_matches_what_the_rest_mapping_provides` pins the
                    # argv's field list against `_rest_pr()`'s keys, so a drift on either side is
                    # red rather than a silently stale mapping behind a healthy-looking line.
                    #
                    # ⛔ RECORD THE CLAIM, THEN WITHDRAW IT. The failure is noted BEFORE the
                    # fallback is tried, so (a) a double refusal reports the same transport failure
                    # it always did, and (b) the withdrawal below retracts a claim that ACTUALLY
                    # EXISTS. Without the note first, `_withdraw_gh_failure()` could never change
                    # anything and the protection its docstring promises would be inert (review
                    # round 1, B and A).
                    _note_gh_failure(f"queue read failed: {_graphql_err}", surface,
                                     transport=primary_transport)
                    # ⛔ THE FALLBACK GETS ITS OWN START-ANCHORED BOUND (#2138 r2, B), CAPPED BY THE
                    # READ'S OWN TICK BUDGET (#2138 r3, A). Passing only the re-sample deadline made
                    # the recovery INERT in the case it exists for: a slow primary read can spend
                    # the whole 20 s budget and then the fallback opens no socket at all. A single
                    # page's worth is always allowed, measured from NOW -- but never past
                    # `read_deadline`, so a refusal that already ate the tick's headroom gets no
                    # socket and raises its own cause instead of pushing the beat into
                    # `run_bounded`'s kill (where no line prints).
                    prs = _queue_rest(
                        deadline=min(_monotonic() + QUEUE_REST_TIMEOUT_S, read_deadline))
                    if prs is None:
                        # Both sources refused: raise the FIRST cause (it is the actionable one --
                        # "rate limit" says wait) and append the second so the cause line names the
                        # whole failure rather than half of it.
                        _rest_err = (GH_LAST_ERROR if "rest second source" in (GH_LAST_ERROR or "")
                                     else "")
                        # The synthesised refusal is a TRANSPORT failure if EITHER source hit
                        # one (#2138 r7, reviewer B). Inheriting only the primary's flag dropped
                        # a genuine rate-limit refusal from the fallback -- measured: a primary
                        # we mangled plus a 403 on REST printed `queue=UNREADABLE` with NO `gh=`
                        # and `VERDICT=UNKNOWN`, where the reader needed "wait for the limit".
                        # A bare parse failure on the primary with a NON-transport fallback
                        # failure still claims nothing, which is the fix from the round before.
                        refusal_transport = primary_transport or _REST_TRANSPORT
                        raise RuntimeError(
                            f"{_graphql_err} | {_rest_err or 'rest second source failed'}")
                    source = "rest"
                    _withdraw_gh_failure(surface)
            else:
                r = _gh_retry(argv, attempts=1, timeout=max(1.0, remaining))
                if r.returncode != 0:
                    raise RuntimeError(((r.stdout or "") + (r.stderr or "")).strip()
                                       or "queue re-read refused")
                prs = json.loads(r.stdout)
                if not isinstance(prs, list):
                    raise ValueError(f"queue payload is not a list: {str(prs)[:200]}")
                # ⛔ THE CAP APPLIES TO A RE-SAMPLE TOO (#2138 r6, A/P2). The guard below on the
                # PRIMARY read exists because `--limit 400` truncates silently, so a full page
                # published as the depth is an under-count. A re-sample had no such guard, and it
                # is ACCEPTED rather than rejected -- a deeper sample wins and a fully-readable
                # full page is not blind, so `queue()` breaks with it and publishes `waiting=400`
                # for a 500-PR backlog. Reachable when the first sample was BLIND.
                if len(prs) >= QUEUE_PRIMARY_LIMIT:
                    raise ValueError(f"{len(prs)} open PRs is the primary read's cap, "
                                     f"not the queue")
            non = [p for p in prs if not p["isDraft"]]
        except Exception as e:
            # A FAILED RE-SAMPLE MUST NOT THROW AWAY A SAMPLE WE ALREADY HOLD. The first read
            # ANSWERED, so `queue=UNREADABLE` would discard `open`/`nondraft`/the DO list to
            # report a fact that is strictly less informed. `transport=False` on a PARSE failure
            # (the transport worked, we mangled the answer -- not blindness), and the surface
            # differs on a re-sample: `"queue-resample"` is deliberately NOT one of
            # BLINDING_SURFACES, because the queue WAS read -- a transient failure of a RE-read
            # must not declare the fleet blind, rewrite the verdict to RATE-LIMITED, or suppress
            # the cache, all of which is worse than not having re-read.
            transport = (refusal_transport if refusal_transport is not None
                         else isinstance(e, (RuntimeError, subprocess.TimeoutExpired)))
            _note_gh_failure(f"queue read failed: {e}", surface, transport=transport)
            if sample is None:
                return None
            resample_failed += 1
            break
        reads += 1
        ms = Counter(p.get("mergeStateStatus") or "?" for p in non)
        unknown = _mergeable_unknown(ms)
        blind_now = _queue_read_is_blind(unknown, len(non), source)
        # KEEP THE MOST RESOLVED SAMPLE, NOT THE LAST ONE. A later sample can land inside a
        # SECOND recompute window (the queue keeps moving while we wait) and would otherwise
        # clobber a better reading with a worse one. Ties go to the later sample, which is the
        # fresher queue. Each sample is kept WHOLE -- counts, classes and list never mix.
        # ⛔ A READABLE ANSWER WINS -- UNLESS IT IS EMPTY. `blind and smaller` is the degenerate
        # shape (14 blind PRs, then an empty list = "0 unread" = a CLEARED queue of zero, and
        # `waiting < TARGET_PRS` would read AT-TARGET): that is the false all-clear this
        # instrument exists to refuse, manufactured by the retry itself. But `readable and
        # smaller` is the ORDINARY event of a PR landing during the wait -- 14 blind, then 13
        # fully readable -- and rejecting it would report BLIND with the blind sample's DO list
        # while a complete answer was in hand: exactly the harm this retry exists to remove.
        # ⛔ AND A SAMPLE THAT GAINED PRs IS ACCEPTED EVEN WITH MORE UNREAD ONES: a degraded
        # first answer that under-counts (3 of 14) must not survive as the final measurement, or
        # the same false all-clear arrives from the other direction (`waiting=3` => AT-TARGET).
        accepted = (sample is None
                    or len(non) > len(sample["non"])
                    or (not blind_now and non)
                    or (unknown <= sample["unknown"] and len(non) >= len(sample["non"])))
        if accepted:
            sample = {"prs": prs, "non": non, "ms": ms, "unknown": unknown,
                      "source": source}
        if accepted and not blind_now:
            break
        if attempt == QUEUE_BLIND_ATTEMPTS - 1:
            break
        _sleep(min(QUEUE_BLIND_BACKOFF_S[min(attempt, len(QUEUE_BLIND_BACKOFF_S) - 1)],
                   max(0.0, deadline - _monotonic())))
    prs, non, ms = sample["prs"], sample["non"], sample["ms"]
    unknown = sample["unknown"]
    source = sample.get("source") or "graphql"
    classes, surface, by_class, surface_prs = classify_queue(non)
    blind = _queue_read_is_blind(unknown, len(non), source)
    # ⛔ AN UNREAD MERGE STATE IS *ALWAYS* None, not only when the whole read is blind (#2138).
    # A REST-sourced sample is never BLIND -- the list was read -- but its `mergeable_state` is
    # frequently uncomputed, and `ms.get("DIRTY", 0)` would then publish a FALSE ZERO for a
    # count nobody could read. The same is true of a GraphQL sample with a MINORITY of unread
    # PRs, which the blind predicate deliberately tolerates: tolerating the read is not
    # permission to derive a zero from it.
    unread = unknown > 0
    return {"open": len(prs), "drafts": len(prs) - len(non), "nondraft": len(non),
            # ⛔ None, NOT 0, WHEN THE STATE WAS UNREAD -- `ms.get("DIRTY", 0)` is the exact
            # "an unread value must never render as a zero" shape this file forbids. No consumer
            # reads these two today; making them honest is what stops the next one inheriting a
            # false zero.
            "dirty": None if (blind or unread) else ms.get("DIRTY", 0),
            "unstable": None if (blind or unread) else ms.get("UNSTABLE", 0), "unknown": unknown,
            "source": source,
            "mergeable_reads": reads, "resample_failed": resample_failed,
            "classes": classes, "by_class": by_class, "surface": surface,
            # ⛔ THE OWNER'S LIST SURVIVES THE REFUSAL (#1872): `classify_queue()` returns it in
            # both directions, because "N things need you" without naming them is a stall with a
            # receipt.
            "surface_prs": surface_prs}


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


def pr_doctor_last_run(state_dir: str | None = None) -> str:
    """The LAST pr-doctor pass's verdict, for the beat -- because QUEUE STATE IS NOT PRODUCTION.

    ⛔ MEASURED 2026-10-18, owner-reported, over `$STATE/pr-doctor.launchd.log`, first line 2026-10-10T22:49 -> last 2026-10-18T21:32: 382 passes, 320 `LANE READ FAILED`, 241 carrying `TimeoutExpired`, and TWO that ever dispatched (both 2026-10-11): the beat carried
    `QUEUE(state; pr-doctor dispatches): running=12..23` (relabelled `QUEUE(state):` -- the
    parenthetical claimed a dispatch record the token never carried) -- the QUEUE's shape (how many PRs are
    classified `running`), not a record of any dispatch -- so the fleet read as self-dispatching
    while the SCHEDULED dispatcher was effectively dead, and the owner dispatched PR owners by
    hand. ⚠️ Not "nothing dispatched for six days": the heartbeat's own `$STATE/pr-doctor.log`
    carried the fleet intermittently (87 passes with `dispatched >0` since 2026-10-10, 48 of them
    on 2026-10-17). The claim is about the SCHEDULED path, and it is narrower.

    The dispatcher now writes `$STATE/pr-doctor.status.json` on every exit path (rc + a one-line
    reason). This segment publishes it in the beat, so the same beat that shows the queue also
    shows whether the thing that WORKS the queue is alive -- and says RED when it is not. A
    missing record is `UNREPORTED`, never `ok`: absence is not a pass.
    """
    p = os.path.join(state_dir or STATE, "pr-doctor.status.json")
    # ⛔ A DISARMED DISPATCHER IS NOT A DEAD ONE (2026-10-18, review). `$STATE/PR-DOCTOR-OFF` is the
    # documented way to stop it (heartbeat-loop.sh honours it); the sidecar then stops being written,
    # so an age-bounded reader would print RED every beat forever with no way to tell "the operator
    # turned it off" from "it died" -- a failure manufactured out of an intentional state, on the one
    # token a reader is told to act on. Say DISARMED instead.
    if os.path.exists(os.path.join(state_dir or STATE, "PR-DOCTOR-OFF")):
        return "PR-DOCTOR(last run): DISARMED (PR-DOCTOR-OFF is set)"
    try:
        with open(p) as fh:
            d = json.load(fh)
        rc = int(d.get("rc"))
        age = int(max(0, time.time() - float(d.get("at_epoch") or 0)))
        reason = str(d.get("reason") or "(no reason recorded)")[:110]
        dry = bool(d.get("dry_run"))
    except FileNotFoundError:
        return "PR-DOCTOR(last run): UNREPORTED (no verdict recorded)"
    except Exception as e:
        return "PR-DOCTOR(last run): UNREPORTED (unreadable verdict: %s)" % type(e).__name__
    if dry:
        # A DRY RUN IS NOT A PASS: it stamps no fleet-visible verdict (pr-doctor skips the write),
        # and if an older one ever carries the flag it must never read as production.
        return "PR-DOCTOR(last run): DRY RUN (not a pass)"
    # ⛔ A VERDICT THAT STOPPED BEING WRITTEN IS *UNREPORTED*, NOT `ok` (2026-10-18, review).
    # The failure this whole segment exists to expose is "a dead dispatcher reads healthy"; an
    # unbounded age reproduces it one level up -- kill the launchd job, or touch
    # `$STATE/PR-DOCTOR-OFF`, and the beat would print `ok` forever. The bound is the same
    # freshness the roster read uses (two 1200s dispatch intervals), so the two agree.
    if age > 2400:
        return "PR-DOCTOR(last run): UNREPORTED (verdict is STALE, %dm old: %s)" % (
            age // 60, reason)
    return "PR-DOCTOR(last run): %s rc=%d %dm ago — %s" % (
        "RED" if rc else "ok", rc, age // 60, reason)


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
        # ── THE QUALIFIER GOES FIRST: `queue_read` AND THE OWNER'S LIST PRECEDE THE COUNTS ──
        # ⛔ THE QUALIFIER MUST PRECEDE WHAT IT QUALIFIES (#1869, #1872 review rounds 2 and 4).
        # This line is read with a fixed `cut` by `cadence-nudge.sh` (now `cut -c1-900`), so a
        # fail-closed caveat sitting in the TAIL is the first thing a long queue loses -- and
        # losing it turns a blind read into a clearance, which is the exact fail-open this token
        # exists to prevent. The same is true of `ASK-USER`: `surface=2` alone tells the owner
        # nothing he can act on, and sitting at the END of the queue segment meant a deep queue
        # severed the NUMBERS while leaving the bare count it was added to replace (MEASURED: 60
        # non-draft PRs with a 20-PR overlay loses all 20 names inside the nudge's cut).
        # To a truncating reader, ORDERING IS SEMANTICS.
        _u = q.get("unknown") or 0
        _src = q.get("source") or "graphql"
        _blind = _queue_read_is_blind(_u, q["nondraft"], _src)
        # THE RE-SAMPLE IS NOT SILENT -- neither when it WORKED nor when it failed. A queue that
        # needed a second sample WAS transiently blind (#1869), and saying so is the only way that
        # frequency can be measured; a re-sample that FAILED (timeout, 5xx, garbage) is a different
        # fact again, and it is the datum the backoff budget has to be calibrated from.
        _reads = q.get("mergeable_reads") or 1
        # ⛔ HOW MANY SAMPLES IT TOOK IS PART OF *BOTH* ANSWERS, NOT ONLY THE SUCCESSFUL ONE.
        # "BLIND after 1 read" and "BLIND after 4" are different facts, and `QUEUE_BLIND_BUDGET_S`
        # can only be calibrated from the second: on the settling path the count is the datum, and
        # on the never-settling path it is the only datum there is.
        _rsf = " resample=FAILED" if q.get("resample_failed") else ""
        if _u:
            parts.append(f"mergeable_state_unknown={_u}")
        if _blind:
            # A ZERO FROM A BLIND READ IS NOT A CLEARANCE. Kept from the deleted pair: the
            # fail-closed job belongs to whatever token stands where the zeros used to.
            parts.append(f"queue_read=BLIND({_u}/{q['nondraft']} unread, samples={_reads}){_rsf}"
                         " -- the QUEUE counts are NOT a clearance")
        elif _src == "rest":
            # ⛔ THE FALLBACK MUST NOT MANUFACTURE BLINDNESS (#2138), AND IT MUST NOT PASS FOR A
            # GRAPHQL READ EITHER. A REST-recovered sample DID read the queue -- open, drafts
            # and the whole row set are real -- but REST's `mergeable_state` is frequently ""
            # while GitHub computes mergeability, so the per-CLASS counts may be built on an
            # unread field. Reporting BLIND would be a lie about what was read (and would
            # suppress a real queue depth that a healthy REST call just established);
            # reporting nothing would let an uncomputed merge state pass as a clearance.
            # So the provenance is NAMED, the unread count stays beside it, and the sentence
            # says exactly which half is trustworthy.
            if _u:
                parts.append(f"queue_read=REST(merge_state unread {_u}/{q['nondraft']},"
                             f" samples={_reads}){_rsf} -- list read over REST; GitHub did not"
                             " compute the merge state, so the CLASS counts are NOT a clearance"
                             " (queue depth IS read)")
            else:
                # ⛔ "REFUSED" IS A FALSE CAUSE ON HALF THE TICKS THAT REACH HERE (#2138 r9,
                # reviewer A/P3). This branch also runs when GraphQL ANSWERED with a body this
                # file could not read as a list, and when it hit its own row cap — so the old
                # wording sent a reader to hunt a rate limit that never happened. Saying only
                # what is known costs the same.
                parts.append(f"queue_read=REST(samples={_reads}){_rsf} -- the open-PR list was"
                             " read over REST because the GraphQL read produced no usable list"
                             " (refused, or an answer this file could not read as one)")
            # ⛔ THE FILE OVERLAY IS A THIRD, SEPARATE DEGRADATION, AND OMITTING ITS TOKEN IS
            # A FALSE ABSENCE (#2138 review round 1, B and A and E -- three reviewers, one
            # shape). REST's list endpoint carries no file list, so `touches_surface()` answers
            # False for every row and `surface=0` -- and a reader cannot tell "nobody needs the
            # owner" from "the diff was never read". This file's own rule is that an omitted
            # token is honest ONLY when the value was READ; here it was not, on the one overlay
            # `ASK-USER` exists for. So it is PRINTED as unread, before the `QUEUE(` segment.
            parts.append("ASK-USER: surface=UNREAD(rest list carries no file list)")
        elif _reads > 1 or _rsf:
            parts.append(f"queue_read=SETTLED(samples={_reads}){_rsf}")
        if q.get("surface"):
            _sprs = " ".join(f"#{n}" for n in (q.get("surface_prs") or []) if n)
            parts.append(f"ASK-USER: surface={q['surface']}" + (f": {_sprs}" if _sprs else ""))
        # ── THE PER-CLASS SEGMENT: **STATE**, NOT A SECOND DISPATCH LIST (#1872) ──────────
        # These are the owner-designed action tokens (2026-10-10) -- they replaced `blocked`,
        # which counted `mergeStateStatus=BLOCKED` and needed a sentence of apology ("counter,
        # not a work count") to be read correctly: A VOCABULARY THAT NEEDS AN APOLOGY IS THE
        # WRONG VOCABULARY. MEASURED 2026-10-10 on 10 non-draft PRs: 8 read BLOCKED and 2 DIRTY,
        # and of the 8, FOUR had `ai-review-gate` as their ONLY red -- i.e. RECORD IT, zero code
        # work -- and ONE had never run a required check at all.
        # ⛔ BUT THEY ARE NOT AN INSTRUCTION, and the label says so. `pr-doctor.py` -- the
        # background dispatcher -- already CLASSIFIES AND ACTS on every one of these classes,
        # from the SAME classifier (`classify_one()`), at the machine's configured capacity.
        # The segment used to print as `DO:`, i.e. a second, uncoordinated copy of a decision an
        # automatic chain was already executing; measured 2026-10-16 a beat printed
        # `DO: call-rail=1: #8795 (STUCK 3 beats -- land or say why)` while pr-doctor was
        # running its own pass over the same PRs, and the PR then landed BY HAND (`2d52ecc7`).
        # A monitor's job here is to MEASURE AND REPORT: the queue's depth and shape, main's
        # health, and the one thing only a human can take (`ASK-USER`). It never tells the
        # fleet to do work the chain owns; a state token that LOOKS like an order is how a lane
        # gets sent to duplicate live work. Zero tokens are OMITTED: an absent token is honest,
        # a printed zero is a claim.
        # `waiting` is unchanged and load-bearing -- it is the queue depth the verdict compares
        # against `TARGET_PRS`.
        _qcls = q.get("classes")
        if _qcls:
            _bc = q.get("by_class") or {}
            _stuck = _stuck_bump([n for n, _w in (_bc.get("call-rail") or [])])
            seg = " ".join(_class_token(k, _qcls[k], _bc.get(k), _stuck)
                           for k in CLASS_ORDER if _qcls.get(k) and k != "fix-ci")
            # ── IN-PROGRESS: A FIXABLE CI FAILURE IS PROGRESS, NOT BLOCKAGE ──────────────
            # Owner, verbatim: "whenever our tests discover something that needs fixing before
            # running CI again, you label it as blocked instead of doing the work that is
            # needed ... having to fix things is a NATURAL PART OF THE CI PROCESS." He was
            # right, and it was a design defect, not a reporting nit: `fix-ci=13` rendered a
            # routine repair step as a wall, the orchestrator reported a wall, and NOTHING in
            # the system did the work -- 25 PRs sat while every beat printed a count. A PR whose
            # next step is "fix the failing test" HAS AN OWNER AND AN ACTION; it is MOVING.
            # Only ASK-USER and a genuine external wait are ever "not moving".
            # Each entry names WHICH check failed and how many PRs, so the QUEUE's SHAPE is
            # legible and a routine repair can be read as MOVING -- not so a lane learns what to
            # open: the repair is pr-doctor's, dispatched from this same classifier, and the
            # instruction-shaped rationale this line used to carry is exactly what the header
            # above this block removed.
            if _qcls.get("fix-ci"):
                _cnt = defaultdict(int)
                for _num, _why in (_bc.get("fix-ci") or []):
                    for _nm in (_why or "?").split(","):
                        if _nm:
                            _cnt[_nm] += 1
                if _cnt:
                    seg += " IN-PROGRESS: fixing " + " ".join(
                        f"{n}={c}" for n, c in sorted(_cnt.items(), key=lambda kv: (-kv[1], kv[0])))
            parts.append(f"waiting={q['nondraft']} prs: {q['nondraft']} nondraft")
            parts.append(f"| QUEUE(state): {seg}")
        else:
            # `classes` is None when ANY PR's checks were unreadable, so no partition is printed.
            parts.append(f"waiting={q['nondraft']}")
        # ⛔ `blocked` IS DELETED AS A TOKEN, AND SO IS ITS CAVEAT. Do not re-add either.
        # Anything that needs a sentence of apology to be read correctly is the wrong vocabulary.
        # The per-class tokens above say what the queue LOOKS LIKE and who acts on it; they do
        # not instruct, because `pr-doctor` is already doing exactly that work.
        waiting = q["nondraft"]
    else:
        parts.append("queue=UNREADABLE")
        waiting = None
    # ⛔ THE QUEUE'S SHAPE IS NOT THE DISPATCHER'S HEALTH, AND THE VERDICT MUST SURVIVE BOTH A BLIND
    # QUEUE AND A LONG ONE (2026-10-18, owner-reported + review). Emitted OUTSIDE every queue branch
    # -- a partly-blind pass is exactly when a reader most needs to know whether the thing that works
    # the queue is alive, and a segment that disappears with the queue read is indistinguishable from
    # "green". `pr_doctor_last_run()` reads its own file and answers its own question.
    #
    # ⚠️ AND IT IS EMITTED **HERE**, BEFORE `waiting=`/`QUEUE(state):`, NOT AFTER THEM. The fleet reads
    # this line through a fixed `cut -c1-900` (`cadence-nudge.sh`), and that file's own rule says what
    # a cut CAN sever is "the tail of the queue segment and then the CI indicators" -- so appending
    # the one fact this change adds would have put the RED exactly in the severable region, and a long
    # queue would cut the dispatcher's verdict first. Only latent while the line measured ~466 chars;
    # it would not stay latent.
    parts.append("| " + pr_doctor_last_run())
    if crit:
        # INDICATOR, not a target (see GUIDELINE_CI_MIN). MEDIAN critical path and the worst
        # seen -- the worst is what a PR actually waits for, because one slow shard is the
        # path. Reported so the suite CAN be improved; it does not decide the verdict.
        parts.append(f"ci_crit_med={crit:.1f}m ci_crit_max={crit_max:.1f}m({crit_job})")
        parts.append(f"ci_guideline={GUIDELINE_CI_MIN:.0f}m:"
                     f"{'over' if (crit_max and crit_max > GUIDELINE_CI_MIN) else 'within'}")

    # -- the verdict: ONE word the heartbeat can alert on ----------------------
    if GH_BLOCKED == "RATE-LIMITED":
        verdict = "GH-RATE-LIMITED"  # NOT a property of the tree: the fleet cannot read
    elif mstate == "RED":
        verdict = "FIX-MAIN"         # main is RED. The beat prints failing_required=<check>
                                      # beside this; the WORK is fixing that check. There is no
                                      # `DO:` token for the PR CLASSES any more (that segment is
                                      # state, #1872) -- the RES band still emits its own
                                      # `| DO: <band>`, which is this file's dispatch gate.
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

# ── DISPATCH ADVISORY (owner 2026-10-11) -- a HUMAN HINT, NOT A BAND ─────────────────────
# ⛔ THIS IS DELIBERATELY NOT PART OF THE BAND, AND MUST NEVER STEER `res_action()`. This block
# already records why load is not a band input: load is a LAGGING average (1/5/15 min) and cannot
# answer "right now", which is what `runq` answers. That decision STANDS -- `runq` remains the
# machine's saturation band and `load` is not in RES_REQUIRED. What the owner asked for is an
# ADVISORY in plain words, exactly as `mem` and `swap` are already printed without banding.
#
# ⛔ THE TWO SIGNALS WILL SOMETIMES DISAGREE (a high runq with a still-low load average is the
# normal transient, because load has not caught up). THAT IS EXPECTED AND CORRECT -- do not
# "fix" it by feeding load into the band, and do not delete the advisory to remove the apparent
# contradiction. Two signals, two jobs: `runq` = is the box saturated RIGHT NOW (band);
# `load` = should I add work (human hint).
#
# Basis: measured 2026-10-11 on this 10-core box (state/DISPATCH-THRESHOLDS-2026-10-11.md):
#   load 41-46   -> queue DRAINED (waiting 25 -> 15); 76 = transition (NOT drained)
#   load 101-143 -> queue FLAT for hours
#   load 156+    -> REGRESSED (waiting 15 -> 17)
# i.e. ~10x cores. Refine as more data lands.
LOAD_REFUSE = 100    # at/above -> recommend NOT dispatching new work
LOAD_CAUTION = 50    # at/above -> recommend ONE lane at a time
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


def _load_avg():
    """The 1-minute load average, or None when it could not be read.

    ⛔ None, NEVER 0 -- an unread load must SAY SO. A fabricated `0` would read as "idle box",
    and the advisory built on it would say "dispatch freely" on a machine nobody measured.
    1-minute (not 5/15) because this is a hint about the next few minutes, which is the window
    a dispatch decision covers.
    """
    try:
        return float(os.getloadavg()[0])
    except Exception:
        return None


def load_advisory(r):
    """The `ADVISORY:` clause for the RES line -- a HUMAN hint, never a band.

    ⛔ REPORTED, NOT BANDED. This function must never be called from `res_action()`, and `load`
    must never join RES_REQUIRED: the advisory states a recommendation in words while the BAND
    keeps deciding, so the box can be advised against dispatch while the band still says
    dispatch-one (which is the intended reading, not a bug).

    Four outputs, and the unread case is one of them: a load we could not read is `unread`, and
    it NEVER implies "dispatch freely" -- a failed read is not an empty success.
    """
    v = r.get("load")
    if v is None:
        return "load=unread ADVISORY: unknown"
    if v >= LOAD_REFUSE:
        return "load={:.0f} ADVISORY: DO NOT DISPATCH new work until the next heartbeat".format(v)
    if v >= LOAD_CAUTION:
        return "load={:.0f} ADVISORY: dispatch ONE lane at a time".format(v)
    return "load={:.0f} ADVISORY: dispatch freely".format(v)


def resources():
    """The `RES:` signals, each None when it could NOT be read (see res_action).

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
    # REPORTED ONLY -- never banded, never in RES_REQUIRED, never read by res_action().
    r["load"] = _load_avg()
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
            "res_age={}s {} | DO: {}").format(
        _rf(r.get("cpu")), _rf(r.get("runq")), _rf(r.get("cores")),
        _rf(r.get("mem_used")), _rf(r.get("pressure_free")), _rf(r.get("swap")),
        _rf(r.get("swap_act")), top, age, load_advisory(r), res_action(r))


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
    # `RES:` GOES ON ITS OWN LINE -- and NOT because the objective line is too long for the cut
    # (#1872 review round 18: that sentence was false the moment the cut reached 900, and MEASURED
    # an objective line is ~300 chars; the sibling comment in `cadence-nudge.sh` says the same).
    # Two reasons that do hold: (1) appending it puts the LIVE resource numbers behind everything
    # the objective segment can grow into, and the tail is what a cut reaches first -- so the fix is
    # to move them out, not to argue about widths; (2) `cadence-nudge.sh` must refresh it EVERY beat
    # without re-deciding the verdict, which is what its own cache paragraph records. The
    # fail-closed `queue_read=BLIND` caveat is emitted BEFORE the queue segment, so truncation can
    # never drop it either way.
    try:
        res = res_line()
    except Exception as e:
        res = f"RES: UNKNOWN error={str(e)[:60]} | DO: UNKNOWN"
    # ⛔ A FAILED READ MUST NOT BE CACHED (2026-10-03).
    # The cache is mtime-keyed and holds ONE line, so it cannot tell a good read from a failed
    # one -- and a failure therefore inherits the FULL serve window (900 s when this was measured;
    # `VERDICT_SERVE_MAX_S` clamps it to 120 s today, which does not make the guard unnecessary --
    # two minutes of a blind line is still a blackout). MEASURED: at 16:59 a
    # transient GitHub 5xx (its own "No server is currently available", REST 4/5, GraphQL 5/5,
    # rate limits 5000/5000) wrote `main=UNKNOWN@? gh=UNREADABLE(queue) queue=UNREADABLE` into
    # this cache, and every heartbeat tick until 17:14:53 served it -- while a FORCED read at
    # 17:07 returned `ADVANCING main=GREEN@478c5e0e4`. One blip became a 15-MINUTE BLACKOUT.
    # The retry in _gh_retry absorbs the blip at source; this stops a surviving one from being
    # frozen. Both are the same rule this file's header already states in another form: an
    # empty read and an absent thing must never share a word -- and must never share a cache.
    blind = ("gh=UNREADABLE" in line or "main=UNKNOWN@?" in line or "error=" in line
             # ⛔ AND AN UNREAD QUEUE IS A FAILED READ EVEN WHEN NO SURFACE CLAIMED BLINDNESS
             # (#2138 r5, A/P2). A payload the primary could not use AND no second source is a
             # non-transport failure -- correctly not a claim (`transport=False`: GitHub answered,
             # we mangled it) -- but the line then says `queue=UNREADABLE` with no `gh=` token, so
             # this guard matched nothing and FROZE the blind line for the whole serve window. The
             # guard keys on the FACT (the queue could not be read), not on which token said so.
             or "queue=UNREADABLE" in line)
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
