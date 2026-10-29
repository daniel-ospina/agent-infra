#!/usr/bin/env python3
"""Drive every open non-draft PR toward merged -- the ACTION half of the heartbeat.

WHY THIS EXISTS (owner, verbatim): "whenever our tests discover something that needs fixing
before running CI again, you label it as blocked instead of doing the work that is needed and
continuing with the merge process (having to fix things is a natural part of the CI process) ...
i need you to find a way to make it automatic."

`waiting` went 10 -> 25 in one day while the fleet worked hard the entire time. The work was
never missing: THE LAST MILE HAD NO AUTOMATION, so every failing check became a report instead
of a repair. This closes that loop. It runs on a timer, reads the checks the heartbeat already
reads, and ACTS.

HARD REQUIREMENTS (each is a guard below, not a good intention):
  1. FIX AND RAIL IN THE SAME RUN. The gap between "recorded" and "merged" cost #7906 35 min,
     #7922 25, #7904 90+. Never dispatch a fix without instructing the merge that follows it.
  2. IDEMPOTENT. Never two lanes on one PR -- worse than one lane being slow -- so a PR with a
     live lane is skipped, and the lane record is checked before every dispatch.
  3. BOUNDED. Max N concurrent fix lanes, so it cannot saturate the box and time out its own CI
     (#5049 is caused by exactly that). The cap comes from the SAME `RES:` band the heartbeat
     uses, so the two cannot disagree about whether the box can take work.
  4. LOGGED. Which PR, which action, which lane -- so the next beat shows WORK DISPATCHED
     rather than a count of stuck things.
  5. RESPECTS THE BOX. `DO: hold|RECLAIM|UNKNOWN` dispatches nothing, however long the queue.
  6. NEVER DISPATCHES FROM A QUEUE WHOSE CLASS COUNTS ARE NOT A CLEARANCE. `queue()` returns
     classes even when the merge-state read was blind; the beat qualifies that with "NOT a
     clearance" and this file, which ACTS, holds on the SAME question
     (`objective._class_counts_are_a_clearance`, which delegates to the beat's blindness
     predicate for GraphQL and qualifies a REST pass on its provenance: EVERY REST row's merge
     state is unread, so acting there would misroute a conflicted PR instead of resolving it)
     (#1918, #1942 review A/P2).

Default is `--dry-run`: it prints exactly what it would do. `--act` performs the dispatches.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
STATE = os.path.expanduser("~/.pi/agent/state")
LANES_FILE = os.path.join(STATE, "pr-loop-lanes.json")
LOG_FILE = os.path.join(STATE, "pr-loop.log")


def _objective():
    # ⛔ THE REPO IS AN INPUT, AND IT MUST COME FROM THIS CHECKOUT (#2040/#1901).
    # `objective.py` reads its repo from `OBJECTIVE_REPO` and DEFAULTS to
    # daniel-ospina/tortoise. Nothing in this loop supplied it, so on ANY other repo the loop
    # graded tortoise's PRs from ITS OWN checkout: every read succeeded, the classifier answered
    # about the wrong queue, and the pass looked alive while acting on PRs this box does not own.
    # That is the measured #2700 shape — `58 PR(s) had UNREADABLE checks … No commit found for SHA
    # f75d30d3` (a 422 for every PR, because the SHAs were another repo's).
    #
    # ⛔ ONE DERIVER, NOT A SECOND PARSER: `scripts/orchestrator-harness/repo-slug.sh`'s
    # `derive_or` is the fleet's single answer to "which owner/name is this checkout", shared with
    # orch-loop.sh and refresh-candidates.sh. A python copy would be a THIRD derivation — the drift
    # repo-slug.sh exists to end — so the slug is obtained by sourcing that file.
    #
    # ⚠️ THIS BINDS THE **REPO** INPUT ONLY, AND SAYS SO. `objective.py` has a SECOND
    # repo-dependent input — its REQUIRED context set (`REQUIRED`, defaulting to tortoise's seven
    # names) — which `repo-authority.sh` resolves for the controllers and which NOTHING supplies
    # here. Binding it means one `gh` protection read per pass and changes the class of every
    # dispatch this loop makes, so it belongs with the caller-side fix #2700 already names as C5's
    # acceptance criterion; doing it inside a repo-binding fix would change the fleet's behaviour
    # unreviewed. Stated, not silently assumed bound.
    #
    # ⛔ AND THE DERIVER MUST TRAVEL WITH THIS FILE. `_checkout_repo` sources
    # `scripts/orchestrator-harness/repo-slug.sh`; a box that farms `pr-loop.py` WITHOUT that file
    # gets the refusal below (fail-closed, never a guess) — so any future farm list carrying this
    # script must carry the deriver too.
    if not os.environ.get("OBJECTIVE_REPO"):
        derived, why = _checkout_repo()
        if not derived:
            # ⛔ THREE CAUSES, THREE REMEDIES, NAMED SEPARATELY. Collapsing them made the operator
            # apply the stated remedy ("run from the checkout you mean") forever on a box that is in
            # fact MISSING the deriver — the loop stays dead and the message points elsewhere. The
            # same collapse ate the THIRD cause too (ai#2922 review, P1): `cwd-unreadable` was
            # computed by `_checkout_repo` and then reached the `underivable` branch below, which
            # tells an operator holding a launchd cwd failure to debug their origin remote. Each
            # branch below states the remedy for the cause it was actually given.
            if why == "deriver-missing":
                raise SystemExit(
                    "pr-loop: cannot bind this checkout's repo — the ONE slug deriver is MISSING "
                    "next to this script (looked for orchestrator-harness/repo-slug.sh and "
                    "repo-slug.sh). Refusing to grade ANOTHER repo (the classifier's fallback is "
                    "daniel-ospina/tortoise). Remedy: deploy scripts/orchestrator-harness/repo-slug.sh "
                    "with this file, or export OBJECTIVE_REPO=<owner/name>.")
            if why == "cwd-unreadable":
                raise SystemExit(
                    "pr-loop: cannot read this process's working directory — the OS refused "
                    "(PermissionError/ENOENT; a sandboxed launcher with no Full Disk Access). "
                    "Refusing to grade ANOTHER repo (the classifier's fallback is "
                    "daniel-ospina/tortoise). Remedy: move the job's WorkingDirectory out of the "
                    "protected tree, or export OBJECTIVE_REPO=<owner/name>.")
            raise SystemExit(
                "pr-loop: cannot derive this checkout's repo from its origin remote — refusing to "
                "grade ANOTHER repo (the classifier's fallback is daniel-ospina/tortoise). Run from "
                "the checkout you mean, or export OBJECTIVE_REPO=<owner/name>.")
        os.environ["OBJECTIVE_REPO"] = derived
    spec = importlib.util.spec_from_file_location("objective_loop", HERE / "objective.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _safe_cwd():
    """The process's cwd, or None when the OS REFUSES to say where the process is.

    ⛔ `os.getcwd()` IS NOT A TOTAL FUNCTION (ai#2922) -- see the twin in `objective.py`'s
    `_checkout_repo`, which this shim mirrors deliberately. Under launchd with no Full Disk Access
    the call RAISES (`PermissionError`, or `FileNotFoundError` for a deleted `WorkingDirectory`)
    instead of returning a path.
    """
    try:
        return os.getcwd()
    except OSError:                            # PermissionError, ENOENT, ENOENT-after-delete
        return None


def _checkout_repo(path=None):
    """(slug, reason): `owner/name` of the checkout this loop acts on, or (None, why).

    Sourced, never re-implemented — see the block above `_objective`. The reason is "deriver-missing"
    when the script is deployed without repo-slug.sh, "cwd-unreadable" when the OS refuses to report
    the working directory, else "underivable" — three different remedies, reported rather than
    collapsed (ai#2922: a cwd failure used to reach the broad `except` below and be reported as
    "underivable", whose remedy is to debug `git`/`bash`).
    """
    lib = None
    for cand in (HERE / "orchestrator-harness" / "repo-slug.sh", HERE / "repo-slug.sh"):
        if cand.is_file():
            lib = cand
            break
    if lib is None:
        return None, "deriver-missing"
    # ⛔ RESOLVED OUTSIDE THE `try`: a cwd that cannot be read is a NAMED cause.
    if not path:
        path = _safe_cwd()
        if path is None:
            return None, "cwd-unreadable"
    try:
        res = subprocess.run(
            ["bash", "-c", '. "$1" >/dev/null 2>&1; derive_or "$2"', "_", str(lib),
             str(path)],
            capture_output=True, text=True, timeout=30)
    except Exception:
        return None, "underivable"
    if res.returncode != 0:
        return None, "underivable"
    slug = (res.stdout or "").strip()
    return (slug, "") if slug else (None, "underivable")


def log(msg):
    line = f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}"
    print(line)
    try:
        with open(LOG_FILE, "a") as fh:
            fh.write(line + "\n")
    except Exception:
        pass


def load_lanes():
    """{pr: {"lane": id, "started": ts, "action": str}} -- the idempotence ledger."""
    try:
        with open(LANES_FILE) as fh:
            return json.load(fh)
    except Exception:
        return {}


def save_lanes(d):
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(LANES_FILE, "w") as fh:
            json.dump(d, fh, indent=1)
    except Exception:
        pass


def lane_live(lane):
    """A lane is live only if its cmux workspace still exists -- the same 'measure, don't infer'
    rule as everywhere else. An absent workspace releases the slot."""
    try:
        r = subprocess.run(["cmux", "list-workspaces", "--json"],
                           capture_output=True, text=True, timeout=30)
        return lane in (r.stdout or "")
    except Exception:
        return True          # cannot PROVE it is gone → hold the slot, never double-dispatch


def decide(klass, why):
    """(action, detail). A FIX ALWAYS CARRIES THE RAIL IT IS FOR (hard requirement 1)."""
    if klass == "running":
        # The head is still EXECUTING (#1872): a required check in flight, OR a required gate that
        # has NOT YET REPORTED while anything at this head is in flight -- `objective.py`'s arm is
        # `(gated_flight or (gated_absent and flight)) and not gated_red`. Without this arm the class
        # falls through to the `ask-user` default below and a lane that is merely WAITING is
        # reported as an owner decision. Reading this narrowly ("only a mid-run required check")
        # is how a correct `running` gets tightened back into work.
        return "wait", None
    if klass == "call-rail":
        return "rail", None
    if klass == "rerun-checks":
        # ⛔ CARRY THE REASON (#1926). It names WHICH check and HOW LONG it has been stuck
        # (`python-ci-gate queued 150m`), which is the difference between "the required checks
        # never got created" and "this one has been wedged for hours" -- two different repairs.
        # Dropping it left the brief saying only "re-run the required checks".
        return "rerun", (f"re-run {why}" if why else "re-run the required checks")
    if klass == "resolve-conflict":
        return "fix", "rebase on main, then record+rail"
    if klass == "record-review":
        return "review", "fresh-context reviewer, record, then rail"
    if klass == "blocked-by-rail":
        return "fix", f"repair {why}, then re-review and rail"
    if klass == "fix-ci":
        return "fix", f"repair {why}, then re-review and rail"
    return "ask-user", None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--act", action="store_true", help="perform dispatches (default: dry-run)")
    ap.add_argument("--max-lanes", type=int, default=None)
    args = ap.parse_args()

    o = _objective()
    r = o.resources()
    band = o.res_action(r)
    # HARD REQUIREMENT 5 + 3: the cap comes from the SAME band the heartbeat prints, so the
    # dispatcher can never believe the box is healthier than the line says it is.
    cap = args.max_lanes if args.max_lanes is not None else \
        {"dispatch-many": 3, "dispatch-one": 1}.get(band, 0)

    lanes = load_lanes()
    for pr in list(lanes):                      # release slots whose lane is gone
        if not lane_live(lanes[pr].get("lane", "")):
            log(f"RELEASE #{pr} (lane {lanes[pr].get('lane')} gone)")
            lanes.pop(pr)

    q = o.queue()
    if not q or not q.get("classes") or q.get("classes").get("fix-ci") is None and not q.get("by_class"):
        log("no readable queue -- doing nothing (a miss must never become an action)")
        save_lanes(lanes)
        return 0

    by_class = q.get("by_class") or {}
    log(f"band={band} cap={cap} active={len(lanes)} nondraft={q['nondraft']}")

    # ⛔ THE COUNTS ARE REAL; THE CLEARANCE IS NOT. `queue()` returns classes even when the
    # merge-state read was blind, so the guard above does not fire (it only fires when a per-PR
    # CHECK-RUN read failed and `classes` is None). The beat QUALIFIES such a queue with
    # "NOT a clearance"; this file ACTS on it, and its own rule is "a miss must never become an
    # action" -- so a queue whose CLASS counts are not a clearance dispatches nothing (#1918).
    #
    # The predicate is `objective._class_counts_are_a_clearance`, NOT a second definition of
    # "is this dispatchable": two thresholds would drift and the dispatcher would decide on a
    # classification its own report calls untrustworthy. That ONE function is the clearance
    # question -- "may the CLASSES be acted on" -- and it DELEGATES to the beat's own blindness
    # predicate for a GraphQL read, so a re-threshold moves both sites instead of orphaning
    # this one. Its signature is the beat's own `(unknown, nondraft, source)` -- NOT the queue
    # dict -- so this call site is forced to move with it.
    #
    # ⛔ THE THIRD ARGUMENT IS NOT DECORATION, AND IT POINTS THE OTHER WAY FROM #2138 (#1942
    # review, A/P2 -- this comment previously claimed the opposite and was WRONG). A REST-sourced
    # sample is NOT `queue_read=BLIND`: REST answers the LIST, so the beat does not borrow the
    # blindness word for it. But it does NOT call such a queue readable either -- it prints
    # "GitHub did not compute the merge state, so the CLASS counts are NOT a clearance", because
    # `_rest_pr()` leaves `mergeStateStatus` None for EVERY row (`unknown == nondraft`). This
    # file acts on the CLASSES, so it holds too; passing the provenance is what lets it hold for
    # the RIGHT reason (and say so) instead of calling a REST read blind. The priced residual:
    # while the GraphQL read is refused, no lane is dispatched -- the alternative is acting on a
    # wholly-unread classification, where `classify_pr()`'s DIRTY arm cannot even fire, so a
    # CONFLICTED PR gets a `call-rail`/`fix-ci` brief instead of `resolve-conflict` (concentrated
    # in one tick, and the beat holds its slots open: the release sweep above still runs).
    _unknown = q.get("unknown") or 0
    _src = q.get("source") or "graphql"
    if not o._class_counts_are_a_clearance(_unknown, q["nondraft"], _src):
        if _src == "rest":
            log(f"HOLD -- queue_read=REST(merge_state unread {_unknown}/{q['nondraft']}): the"
                f" list was read over REST and GitHub did not compute its merge state, so the"
                f" CLASS counts are NOT a clearance (nondraft={q['nondraft']} is real) --"
                f" dispatching nothing (a miss must never become an action)")
        else:
            log(f"HOLD -- queue_read=BLIND({_unknown}/{q['nondraft']} mergeable_state unread): "
                f"nondraft={q['nondraft']} is measurable but the classes above it are NOT a clearance "
                f"-- dispatching nothing (a miss must never become an action)")
        save_lanes(lanes)
        return 0

    dispatched = 0
    for klass in o.CLASS_ORDER:
        for num, why in by_class.get(klass) or []:
            action, detail = decide(klass, why)
            if action == "wait":                 # in flight: nothing to dispatch, nothing to ask
                continue
            if num in lanes:                    # HARD REQUIREMENT 2: idempotent
                log(f"SKIP #{num} ({klass}) -- lane {lanes[num]['lane']} already working it")
                continue
            if action in ("fix", "review") and dispatched >= cap:
                log(f"HOLD #{num} ({klass}) -- cap {cap} reached (band={band})")
                continue
            if action == "ask-user":
                log(f"ASK-USER #{num} -- surface change, the only real human gate")
                continue
            lane = f"prloop-{num}"
            log(f"{'ACT' if args.act else 'DRY'} {action} #{num} ({klass}) "
                f"{('— ' + detail) if detail else ''} lane={lane}")
            if args.act:
                # The dispatch is the ONLY side effect, and it is recorded BEFORE it happens so
                # a crash mid-dispatch cannot lose the idempotence record.
                lanes[num] = {"lane": lane, "started": time.time(), "action": action}
                save_lanes(lanes)
            if action in ("fix", "review"):
                dispatched += 1

    save_lanes(lanes)
    log(f"done: {dispatched} dispatched, {len(lanes)} slots held")
    return 0


if __name__ == "__main__":
    sys.exit(main())
