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

# ── protected lanes: never dispatched to, whatever their verdict says ─────────────
# HANG is the owner's park lane; the DMeer lanes are the owner's own work.
PROTECTED = ("HANG", "DMeer", "DMer", "π - DMeer", "DMeer -")

COOLDOWN_S = 15 * 60

# class -> (queue file, human label)  the queue to pull from for that class
CLASS_QUEUE = {
    "land":     ("LANDABLE.tsv", "land the next candidate via the rail"),
    "1-RETRY":  ("REMEDY.tsv",   "main is GREEN now -> just re-run the rail"),
    "2-RAIL":   ("REMEDY.tsv",   "rail moved the head and refused (see #6160)"),
    "3-BLINDSPOT": ("REMEDY.tsv", "no parseable failure identity (#6798)"),
    "4-REVIEW": ("REMEDY.tsv",   "review at the CURRENT head, then record"),
    "5-FIX":    ("REMEDY.tsv",   "a genuine failure -> fix code or test"),
}


def sh(cmd, timeout=90):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return None, "(timeout)"


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


def no_wip(row: dict) -> tuple[bool, str]:
    """Positive evidence that nothing is in flight, from the classifier's own signals."""
    if row.get("verdict") != "DONE-IDLE":
        return False, f"verdict={row.get('verdict')}"
    if row.get("grew"):
        return False, "session GREW during the sample window (a turn is in flight)"
    if row.get("spinner"):
        return False, "pane shows `Working`"
    if row.get("child") or row.get("declared"):
        return False, "has a pending/declared child (work happening off-root)"
    stale = row.get("stale_s")
    if stale is None or stale < MIN_IDLE_S:
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


def lanes():
    """Per-lane verdicts from the existing multi-signal classifier (do not reinvent)."""
    rc, out = sh(["python3", LANE_STATUS, "--json"], timeout=300)
    if rc != 0 or not out.strip().startswith("["):
        return []
    try:
        return json.loads(out)
    except Exception:
        return []


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


def claim_next(lane_id: str, queue_file: str):
    """Take the next unclaimed item for this lane FROM THE QUEUE ITS CLASS NAMES.

    MEASURED DEFECT this argument closes: `claim.py` reads LANDABLE.tsv and nothing else.
    Called without --queue it answers NONE for a REMEDY lane -- correctly, because it never
    read REMEDY.tsv -- and a dispatcher that trusted that answer would report "nothing left"
    forever while 46 work orders sat unread. An empty result from a queue you did not read is
    not evidence of absence (the same rule that caught the unguarded find earlier).
    """
    path = os.path.join(STATE, queue_file)
    rc, out = sh(["python3", CLAIM, "next", lane_id, "--queue", path], timeout=60)
    if rc != 0 or not out.strip():
        return None, path
    first = out.strip().splitlines()[0].strip()
    if not first or first.upper().startswith("NONE"):
        return None, path
    return first, path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="actually send (default: dry run)")
    ap.add_argument("--status", action="store_true", help="report only")
    ap.add_argument("--cooldown", type=int, default=COOLDOWN_S)
    args = ap.parse_args()

    globals()["COOLDOWN_S"] = args.cooldown

    a_raw = assignments()
    a = {norm(k): v for k, v in a_raw.items()}
    rows = lanes()

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
    print(f"lanes read  : {len(rows)}   DONE-IDLE (dispatchable): {len(idle)}")
    if withheld:
        print(f"              WITHHELD — DONE-IDLE but no positive no-WIP evidence ({len(withheld)}):")
        for r, why in withheld:
            print(f"    {r.get('lane','')[:34]:34} {why}")
    for r in idle:
        lane = r.get("lane", "")
        cls = a.get(norm(lane))
        mark = cls if cls else "NO ASSIGNMENT -- skipped"
        print(f"    {lane:34} {mark}")

    if args.status:
        return

    print()
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

        qfile = CLASS_QUEUE.get(cls, ("?",))[0]
        item, qpath = claim_next(lane, qfile)
        if not item:
            print(f"  SKIP {lane}: {qfile} has nothing left (read {qpath})")
            continue

        msg = (f"ORCHESTRATOR (automatic queue dispatch): your next item is {item}.\n"
               f"Class: {cls} — {CLASS_QUEUE.get(cls, ('', 'do the remedy'))[1]}.\n"
               f"Queue: {qpath}. "
               f"Record the outcome with: python3 {CLAIM} done {lane} <pr> <LANDED|REFUSED|SKIPPED> \"<reason>\" "
               f"so the queue stays honest, then take the next one. If it prints NONE, stop.\n")

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

        rc, out = sh(["bash", SAFE_SEND, ws, lane, brief], timeout=240)
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
            # AMBIGUOUS: cmux_dispatch reports 'sent-but-not-consumed' — the bytes WERE
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
    print(f"{'(dry run) ' if not args.apply else ''}dispatched {acted}")


if __name__ == "__main__":
    main()
