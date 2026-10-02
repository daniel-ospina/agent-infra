#!/usr/bin/env python3
"""lane-triage.py — turn the WEAK mechanical idle verdicts into TYPED, actionable buckets.

WHY THIS EXISTS (owner, 2026-09-30)
-----------------------------------
The heartbeat's mechanical classifier answers "has this lane written recently?", and that proxy is
unreliable in exactly the case that matters: `lane-status.py` reported **15 of 26 lanes DONE-IDLE**
while the panes showed many of them mid-work. The same failure is already documented inside
`resolve_session` ("the stale id made a working lane read DONE-IDLE for hours").

So the mechanical pass NARROWS the field, and JEV reading each lane's OWN LAST WORDS decides what the
idle actually MEANS. Four idle states need four different actions, and conflating them is what makes
an orchestrator hand a new task to a lane that is mid-task, or nudge a lane that is correctly waiting:

    CONTINUE          mid-task, not blocked, its last words name a next step  -> tell it to continue
    BLOCKED_HUMAN     needs an owner decision                                 -> route to the owner
    BLOCKED_EXTERNAL  waiting on CI / the rail / the queue                    -> report, do not nudge
    DONE_READY        finished, nothing held                                  -> hand it the next item
    STALLED           nothing progressing, nothing awaited                    -> investigate

Only lanes the mechanical pass calls idle-ish (DONE-IDLE / WIP-IDLE / UNBOUND / WEDGED / LONG-TOOL)
are sent to Jev, so the cost stays at one call for the whole idle set (~$0.006 measured for 15).

FAIL-OPEN: if the snapshot or Jev fails, it prints nothing and exits non-zero, and the caller MUST
fall back to the mechanical verdicts. A classifier outage must never hide capacity.

Usage:  lane-triage.py            -> prints shell assignments:  TRIAGE_READY=... TRIAGE_CONTINUE=...
        lane-triage.py --json     -> prints the raw dict
"""
import json
import os
import subprocess
import sys

STATE = os.path.expanduser("~/.pi/agent/state")
PY = "/usr/bin/python3"
IDLE_ISH = {"DONE-IDLE", "WIP-IDLE", "UNBOUND", "WEDGED", "LONG-TOOL", "CHILD-OVERDUE", "CHILD-STUCK"}


def pane_spinning(ws):
    """Is this lane's pane showing a live spinner RIGHT NOW?

    This is the one signal neither classifier can supply: JEV and the mechanical pass both judge the
    last COMPLETED turn, so a lane inside a long tool call (a full test suite, a repo-wide search)
    looks idle to both. Measured 2026-09-30: W0 Test substrate and A read DONE_READY(0.94/0.93)
    minutes after being handed new work and verified WORKING by pane. A wrong DONE_READY re-tasks a
    lane that is mid-work -- the exact dispatch-into-a-busy-lane failure this file exists to prevent.
    """
    if not ws:
        return False
    try:
        out = run(["cmux", "read-screen", "--workspace", ws, "--lines", "8"], timeout=25).stdout
    except Exception:
        return None                      # UNKNOWN, not False -- absence is not evidence
    return ("Working" in out) or ("esc to interrupt" in out)


def run(args, timeout=300):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def main():
    as_json = "--json" in sys.argv

    # 1. mechanical pass — the authority on WHO exists and which lanes are idle-ish
    try:
        mech = json.loads(run([PY, f"{STATE}/../scripts/lane-status.py", "--json", "--sample", "6"]).stdout)
    except Exception as e:
        print(f"lane-triage: mechanical pass failed: {e!r}", file=sys.stderr)
        return 1

    idle_lanes = [r for r in mech if (r.get("verdict") in IDLE_ISH) and not (r.get("child") or {})]
    if not idle_lanes:
        out = {"buckets": {k: [] for k in
               ("CONTINUE", "BLOCKED_HUMAN", "BLOCKED_EXTERNAL", "DONE_READY", "STALLED")},
               "screen": 0, "source": "none"}
        print(json.dumps(out, indent=1) if as_json else "") 
        if not as_json:
            print("TRIAGE_READY=\"\";TRIAGE_CONTINUE=\"\";TRIAGE_HUMAN=\"\";TRIAGE_EXT=\"\";TRIAGE_STALL=\"\";N_TRIAGE=0")
        return 0

    # 2. one Jev call for the whole idle set (snapshot -> typed verdicts)
    try:
        snap = run([PY, f"{STATE}/lane-snapshot.py"], timeout=600).stdout
        with open("/tmp/.lane-triage-snap.json", "w") as fh:
            fh.write(snap)
        vd = json.loads(run([PY, f"{STATE}/lane-verdict.py", "/tmp/.lane-triage-snap.json"],
                            timeout=900).stdout)
    except Exception as e:
        print(f"lane-triage: jev pass failed: {e!r}", file=sys.stderr)
        return 2

    verdicts = {v.get("lane"): v for v in vd.get("verdicts", [])}
    ws_of = {r.get("lane"): r.get("ws") for r in mech}
    buckets = {k: [] for k in ("CONTINUE", "BLOCKED_HUMAN", "BLOCKED_EXTERNAL", "DONE_READY", "STALLED")}
    held = []            # DONE_READY-looking but the pane says it is working -> NOT free capacity
    screened = 0
    for r in idle_lanes:
        lane = r.get("lane")
        v = verdicts.get(lane)
        if not v:
            # not in the snapshot (registry gap) -> leave it to the mechanical verdict
            continue
        screened += 1
        b = v.get("verdict")
        if b == "DONE_READY":
            sp = pane_spinning(ws_of.get(lane))
            # FAIL-SAFE, NOT FAIL-OPEN: an UNREADABLE pane (None) must NOT be read as "not
            # spinning". Measured 2026-09-30: W0 Test substrate was reported DONE_READY(0.93) and
            # listed as free capacity while its pane showed a live spinner -- the read had failed
            # and the failure was silently treated as evidence of idleness. Absence of a signal is
            # not evidence of absence. Only a definite False (pane read, no spinner) passes a lane
            # through as free capacity; True and None both withhold it.
            if sp is not False:
                held.append("%s(%s)" % (lane, {True: "spinning", None: "pane-unreadable"}[sp]))
                continue
        if b in buckets:
            buckets[b].append("%s(%.2f)" % (lane, v.get("confidence") or 0))
    for k in buckets:
        buckets[k].sort()
    held.sort()

    out = {"buckets": buckets, "held_spinning": held, "screen": screened, "source": vd.get("source"),
           "model": vd.get("model"), "usage": vd.get("usage"), "mech_idle": len(idle_lanes)}
    if as_json:
        print(json.dumps(out, indent=1))
    else:
        esc = lambda xs: " | ".join(xs).replace('"', "")
        print('TRIAGE_READY="%s";TRIAGE_CONTINUE="%s";TRIAGE_HUMAN="%s";TRIAGE_EXT="%s";TRIAGE_STALL="%s";TRIAGE_HELD="%s";N_TRIAGE=%d'
              % (esc(buckets["DONE_READY"]), esc(buckets["CONTINUE"]), esc(buckets["BLOCKED_HUMAN"]),
                 esc(buckets["BLOCKED_EXTERNAL"]), esc(buckets["STALLED"]), esc(held), screened))
    return 0


if __name__ == "__main__":
    sys.exit(main())
