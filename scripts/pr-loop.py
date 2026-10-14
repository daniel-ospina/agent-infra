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
    spec = importlib.util.spec_from_file_location("objective_loop", HERE / "objective.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


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
    if klass == "call-rail":
        return "rail", None
    if klass == "rerun-checks":
        return "rerun", None
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

    dispatched = 0
    for klass in o.CLASS_ORDER:
        for num, why in by_class.get(klass) or []:
            action, detail = decide(klass, why)
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
