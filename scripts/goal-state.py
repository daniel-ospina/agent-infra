#!/usr/bin/env python3
"""goal-state.py — QUERY the Tortoise graph for the goal map. It WRITES NOTHING.

⛔ THE GRAPH IS THE MAP. THERE IS NO DOCUMENT, AND THERE MUST NEVER BE ONE.
Three attempts at this file got it wrong in the same way, so the history is recorded here to stop a
fourth:

  1. `CASCADE = [...]` — a hardcoded cascade IN THIS FILE. Deleted.
  2. `seed-goal-map.py`'s `SEED = {...}` — the states and the structure ALSO hardcoded, then written
     into the graph as node properties. That is worse than (1), not better: the graph became STORAGE
     for a document, and the document stayed the real source. The owner caught this: "you're now
     reading a goals doc, but that goals doc is not the graph's goals".
  3. `GOAL.last` — a materialized one-liner, regenerated each tick. Still a DOCUMENT: it drifts the
     moment the reader stops running, and it asserts state it did not compute. Deleted.

So this file only READS. Run it when you need to know where we are:

    .venv/bin/python ~/.pi/agent/scripts/goal-state.py          # the full map
    .venv/bin/python ~/.pi/agent/scripts/goal-state.py --line   # one line, ACTIVE first

Run it with the REPO VENV. The SDK does not import under /usr/bin/python3 (3.9.6) — it compiles a
`{10,512}+` quantifier in tortoise/security.py, which 3.9 rejects ("multiple repeat at position 40").
"""
from __future__ import annotations

import os
import sys

REPO = "/Users/danielospina/Documents/GitHub/tortoise"
sys.path.insert(0, REPO)
os.environ.setdefault("TORTOISE_DB_URI", "docker://:@localhost:16379/tortoise")

TERMINAL = "met"          # a goal whose work is done
NON_GATE = ("guideline",)  # owner #6792: a demoted target; can never block the queue


def read_map() -> dict[str, dict]:
    """The goal layer, straight out of the graph. Nothing here is authored by this file."""
    from tortoise.sdk import TortoiseSDK  # late import: keeps a syntax error cheap to find

    sdk = TortoiseSDK()
    goals: dict[str, dict] = {}
    for p in sdk.query(kind="goal"):
        state = p.get("goal_state")
        if not state:
            # ⛔ A MAP GAP, reported as such. NOT assumed met, and NOT silently skipped: a goal with no
            # state is a hole in the map, and treating "no state" as "fine" is how a map lies.
            state = "<no-state>"
        gid = p["id"]
        goals[gid] = {
            "id": gid,
            "key": p.get("goal_key") or (p.get("content") or gid)[:28],
            "state": state,
            "evidence": p.get("goal_evidence") or "(none recorded)",
            "dep_ids": [d for d in (p.get("goal_depends_on") or "").split(",") if d],
            "checked_at": p.get("goal_checked_at") or "?",
            "status": p.get("status"),
        }
    return goals


def render(goals: dict[str, dict], one_line: bool) -> int:
    if not goals:
        print("MAP GAP: the graph holds no goal nodes. Nothing to read — do NOT assume anything is met.")
        return 1

    def unmet_of(g: dict) -> list[str]:
        return [goals[d]["key"] for d in g["dep_ids"] if goals.get(d, {}).get("state") != TERMINAL]

    active, met, blocked, guidelines, escalated, inert = [], [], [], [], [], []
    for g in goals.values():
        g["waiting_on"] = unmet_of(g)
        if g["state"] == TERMINAL:
            met.append(g)
        elif g["state"] in NON_GATE:
            guidelines.append(g)
        elif g["state"] == "<no-state>":
            blocked.append(g)
        elif g["state"] == "active":
            active.append(g)
            if g["waiting_on"]:  # recorded active though its own preconditions are unmet
                escalated.append((g, f"ACTIVE but deps unmet: {', '.join(g['waiting_on'])}"))
        else:  # unmet / unknown
            blocked.append(g)
            if not g["waiting_on"]:
                escalated.append((g, "deps ALL met but still recorded unmet — ESCALATE"))
        if g["status"] != "live" and g["state"] != TERMINAL:
            inert.append((g, g["status"]))

    order = {"active": 0, "met": 1, "guideline": 2, "unmet": 3}
    live = sorted((g for g in goals.values() if g["state"] in order),
                  key=lambda g: (order[g["state"]], g["key"]))
    groups: dict[str, list[str]] = {}
    for g in live:
        groups.setdefault(g["state"], []).append(g["key"])
    tail = " | ".join(f"{st}:{','.join(ks)}" for st, ks in groups.items() if st != "active")
    holes = [g["key"] for g in goals.values() if g["state"] not in order and g["state"] != "<no-state>"]
    if holes:
        tail += f" | ?:{','.join(holes)}"

    if one_line:
        act = " + ".join(g["key"] for g in active) or "NONE"
        line = f"ACTIVE: {act}" + (f" || {tail}" if tail else "")
        if escalated:
            line = f"ESCALATE: {escalated[0][0]['key']} | " + line
        print(line)
        return 0

    W = 100
    print("=" * W)
    print("GOAL MAP — queried from the TORTOISE GRAPH (no document, nothing cached)")
    print("=" * W)
    for title, group in (("met      ", met), ("ACTIVE   ", active), ("blocked  ", blocked),
                         ("guideline", guidelines)):
        for g in group:
            wo = f"  waiting on: {', '.join(g['waiting_on'])}" if g["waiting_on"] else ""
            print(f"  {title} {g['key']:20s} {g['state']:10s} status={g['status']}{wo}")
            print(f"            {g['evidence'][:94]}")
            print(f"            checked_at={g['checked_at']}")
    print("\n" + "=" * W)
    print(f"ACTIVE SET: {' | '.join(g['key'] for g in active) or '(none)'}")
    if escalated:
        print("\n⚠️  ESCALATION — the graph disagrees with its own preconditions:")
        for g, why in escalated:
            print(f"   {g['key']}: {why}")
    if inert:
        print("\n⚠️  INERT (not `live` → EP treats every operator into it as degenerate; brief rule 7):")
        for g, st in inert:
            print(f"   {g['key']}: status={st}")
    if any(g["state"] == "<no-state>" for g in goals.values()):
        print("\n⚠️  MAP GAPS: a goal with no state is a hole, not a pass — listed under `blocked` above.")
    return 0


def main() -> int:
    try:
        goals = read_map()
    except Exception as e:  # a read that cannot run must never look like an empty map
        print(f"GRAPH UNREADABLE ({type(e).__name__}: {e}) — this is NOT 'no goals', and NOT 'all met'.")
        return 2
    return render(goals, "--line" in sys.argv)


if __name__ == "__main__":
    sys.exit(main())
