#!/usr/bin/env python3
"""seed-goal-map.py — put GOAL STATE into the GRAPH (idempotent; safe to re-run).

⛔ DURABLE HOME (2026-10-09): this was written to /tmp and would have been reaped, leaving the ONLY
writer of goal state unreproducible. It lives here now. Re-run it after any graph restore, and after
adding a goal node. It is the BOOTSTRAP of `goal_depends_on` (the structure); ONGOING state refresh is
goal-state.py --write, which reads what this seeds.

WHAT WAS WRONG (2026-10-09) — all three defects are in the MAP; none needed a new artifact:
  1. The 7 objective goal nodes carried NO goal state. Their only `status` is the graph's draft/live
     lifetime field, so the map had no vocabulary for "done" and could not answer "what is active?".
  2. The dependency EDGES exist but their operator nodes carry NO `label` (keys are only
     [id,is_operator,op_type,direction]) → the cascade DIRECTION was unqueryable. This seed therefore
     carries the preconditions as node properties (`goal_depends_on`, by ID). The unlabelled edges
     remain a defect in the map and are reported, not silently worked around.
  3. The TOP objective (REVENUE) was `status=draft` → per the graph brief's rule 7 a draft goal is only
     ever a TARGET, so EP skips every operator into it as degenerate while still reporting
     `converged=True`. The top of the cascade was INERT.

CORRECTION TO THE FIRST ATTEMPT (caught by read-back, kept here so it is not repeated): the first seed
had the cascade INVERTED (`PILOTS → depends_on → REVENUE`) and keyed preconditions by a DISPLAY NAME the
reader derives differently, so every join silently missed and the reader manufactured two false
escalations. Preconditions are now keyed by ID, and the direction is read off each goal's OWN text
("the precondition for completing P0/P1", "to be resumed once the queue drains").
"""
import os
import sys

sys.path.insert(0, "/Users/danielospina/Documents/GitHub/tortoise")
os.environ["TORTOISE_DB_URI"] = "docker://:@localhost:16379/tortoise"
from tortoise.sdk import TortoiseSDK  # noqa: E402

sdk = TortoiseSDK()

REVENUE, PILOTS, ALPHA = "1a0f4c93565-8ba390705095", "1a0f4c9a91e-a956a099edb6", "1a0f4c9ae4b-70eda40b4c9f"
P0P1, MKTG, MERGE = "1a0f4c9af8a-8b24ff73d40b", "1a0f4c9b189-5ec2d96fe89f", "1a0f4c9b345-7014a92c0f00"
DRAIN, REGIME = "1a0f4c9b542-56f9e229dced", "1a0e87b2433-3aaad65743e4"

# goal_id -> (goal_key, preconditions BY ID [empty = a root, nothing blocks it], state, evidence)
SEED = {
    DRAIN:  ("DRAIN", [], "met",
             "objective.py: waiting=3 < TARGET_PRS(10) — verified 2026-10-09"),
    MERGE:  ("BE-ABLE-TO-MERGE", [DRAIN], "met",
             "the rail lands; ci_crit_med=17.7m vs guideline 10m = INDICATOR, not a gate (owner #6792)"),
    P0P1:   ("P0-P1", [MERGE, DRAIN], "active",
             "both preconditions met; the open P0-blocker + P1-severe set is the work (owner: RESUME once the queue drains)"),
    ALPHA:  ("PRIVATE-ALPHA", [P0P1], "unmet",
             "waiting on P0/P1"),
    MKTG:   ("MARKETING", [], "active",
             "owner-owned; runs in PARALLEL with P0/P1 — not blocked by the alpha, it serves it"),
    PILOTS: ("PILOTS", [ALPHA], "unmet",
             "waiting on the private alpha"),
    REVENUE: ("REVENUE", [PILOTS], "unmet",
             "waiting on pilots"),
    # The owner's #6792 demoted this from a gate to a GUIDELINE. It is a goal node in the graph whose
    # own statement is now a non-gate — recorded as `guideline` so no reader treats it as pass/fail.
    REGIME: ("TARGET-REGIME", [], "guideline",
             "owner #6792: <10 min is a GUIDELINE, not a pass/fail target; it cannot outrank the queue"),
}

print("=== writing goal state into the graph ===")
for gid, (key, deps, state, ev) in SEED.items():
    sdk.update_point(gid, goal_key=key, goal_state=state, goal_depends_on=",".join(deps),
                     goal_evidence=ev, goal_checked_at="2026-10-09T14:45Z")
    print(f"  {key:18s} {state:10s} deps={len(deps)}")

if sdk.get_point(REVENUE).get("status") != "live":
    print("\n  promote REVENUE (rule 7: a draft goal never votes):",
          sdk.promote_point(REVENUE).get("promoted"))

print("\n=== READ BACK (the map must answer from itself) ===")
for gid, (key, deps, *_ ) in SEED.items():
    p = sdk.get_point(gid)
    assert p.get("goal_state") and p.get("goal_key"), f"{key}: property did not persist"
    print(f"  {key:18s} state={p['goal_state']:10s} depends_on={p['goal_depends_on'] or '(root)':50s} status={p.get('status')}")
