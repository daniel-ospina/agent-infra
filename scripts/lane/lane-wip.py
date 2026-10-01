#!/usr/bin/env python3
"""lane-wip — WHAT is this lane's work in progress?

Run this BEFORE sending anything to a lane. `safe-send.sh` answers "may I send"
(active vs idle); this answers the question that actually decides WHAT to send:
did the lane finish, or stop mid-WIP, and if mid-WIP, WHAT is the WIP?

WHY IT EXISTS (measured 2026-09-29, the expensive way):
  The orchestrator sent a generic "clear conflicts" brief to seven lanes based on a
  DONE-IDLE verdict and a minutes-stale pane read. Five of the seven were WORKING and
  had to read the brief from a queue; and `6 Durability core` — genuinely idle — had
  ALREADY ended its last turn with "every leg of main's red is already held, and I
  noted...". It had finished a real investigation. The generic brief told it to start
  unrelated work instead of continuing or reporting what it had. That is a sidetrack
  produced by not reading one message.

THE RULE:
  A verdict (DONE-IDLE / WIP-IDLE) cannot tell "finished" from "stopped with work
  left". The LAST ASSISTANT TURN can, because it says what the lane was doing. So:
    1. run this, read the WIP;
    2. if the WIP is unfinished  -> nudge it to CONTINUE that work, naming it;
    3. if the turn finished      -> hand it the next unheld item for its lane;
    4. if it asked a question    -> route it (ask-owner.py), do not answer it here.

This is the same read-then-route step `turn-classify.py` already performs for the
automatic nudges (it reads the turn, asks Jev what happened, then nudges). The
manual dispatch path had no equivalent, which is how a human-driven send could be
less informed than an automated one.

Usage:  lane-wip.py <label-or-workspace> [--chars N] [--turns N]
"""
from __future__ import annotations
import glob, json, os, subprocess, sys, time

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
SESS = os.path.expanduser("~/.pi/agent/sessions")


def lane_rows():
    out = subprocess.run([sys.executable, os.path.join(SCRIPTS, "lane-status.py"),
                          "--json", "--sample", "2"], capture_output=True, text=True,
                         timeout=240).stdout
    try:
        return json.loads(out)
    except Exception:
        return []


def session_file(sid):
    if not sid:
        return None
    hits = glob.glob(os.path.join(SESS, "*", f"*{sid}*.jsonl"))
    return max(hits, key=os.path.getmtime) if hits else None


def turns(path, want):
    """The last `want` assistant turns, oldest first."""
    got = []
    for line in open(path, errors="ignore"):
        try:
            o = json.loads(line)
        except Exception:
            continue
        msg = o.get("message") if isinstance(o.get("message"), dict) else o
        if (msg or {}).get("role") != "assistant":
            continue
        c = msg.get("content")
        if isinstance(c, str):
            txt = c
        elif isinstance(c, list):
            txt = " ".join(x.get("text", "") for x in c
                           if isinstance(x, dict) and x.get("type") == "text")
        else:
            txt = ""
        if txt.strip():
            got.append(" ".join(txt.split()))
    return got[-want:]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__.split("Usage:")[1].strip()); return 2
    key = args[0].upper()
    chars = 400
    want = 1
    for i, a in enumerate(sys.argv):
        if a == "--chars" and i + 1 < len(sys.argv):
            chars = int(sys.argv[i + 1])
        if a == "--turns" and i + 1 < len(sys.argv):
            want = int(sys.argv[i + 1])

    row = next((r for r in lane_rows()
                if str(r.get("ws", "")).upper() == key
                or str(r.get("lane", "")).upper() == key), None)
    if not row:
        print(f"no lane matches {args[0]!r} — run lane-status.py for the list"); return 2

    sid, verdict = row.get("sid"), row.get("verdict")
    path = session_file(sid)
    if not path:
        print(f"{row.get('lane')}  [{verdict}]  NO SESSION FILE — activity UNKNOWN, do not assume idle")
        return 1
    age = (time.time() - os.path.getmtime(path)) / 60.0
    print(f"LANE    {row.get('lane')}")
    print(f"VERDICT {verdict}   session written {age:.0f}m ago   (id {str(sid)[:8]})")
    print(f"WS      {row.get('ws')}")
    print()
    print("LAST TURN" + ("S (oldest first)" if want > 1 else "") + ":")
    for t in turns(path, want):
        print("  " + t[:chars] + ("…”" if len(t) > chars else ""))
    print()
    print("ROUTE ON THE ABOVE — not on the verdict:")
    print("  unfinished  -> nudge it to CONTINUE that work, naming it")
    print("  finished    -> hand it the next unheld item for its lane")
    print("  a question  -> route it (ask-owner.py); do not answer it here")
    return 0


if __name__ == "__main__":
    sys.exit(main())
