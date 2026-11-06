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

Usage:  lane-wip.py <label-or-workspace> [--chars N] [--turns N] [--json]

EXIT CONTRACT (added for #3382 row 3 — the MCP `lane.artifact` words axis):
  0  the question was ANSWERED — the lane matched and its turns were read. An empty tail is a
     real answer (the lane wrote nothing in its last turn), not an error.
  2  USAGE — no lane matched <label-or-workspace>, or no argument. Nothing was read.
  3  UNMEASURED — the lane matched but its activity could NOT be read (no session file for its
     sid, or `lane-status.py` produced no parseable rows). ⛔ This was exit 1 before: a FAILED
     READ and a CALLER BUG were different codes but the read failure had no name of its own, so
     a consumer reading `!= 0` as "nothing to say" got `idle` out of an unreadable lane — the
     conflation #3382 invariant 1 exists to remove. A consumer must never read 3 as "idle".
"""
from __future__ import annotations
import glob, json, os, subprocess, sys, time

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
SESS = os.path.expanduser("~/.pi/agent/sessions")


def lane_rows():
    """The lane-status rows, or None when they could not be READ.

    ⛔ `None`, NOT `[]`. The old body caught every exception and returned an empty list, so an
    unreadable `lane-status.py` and a fleet with no lanes were the same value — and the caller then
    said "no lane matches <x>", which is a statement about the LANE derived from a failed read.
    (#3382 invariant 1: unknown is not zero.)
    """
    try:
        proc = subprocess.run([sys.executable, os.path.join(SCRIPTS, "lane-status.py"),
                               "--json", "--sample", "2"], capture_output=True, text=True,
                              timeout=240)
        rows = json.loads(proc.stdout)
    except Exception:
        return None
    return rows if isinstance(rows, list) else None


def session_file(sid):
    if not sid:
        return None
    hits = glob.glob(os.path.join(SESS, "*", f"*{sid}*.jsonl"))
    if not hits:
        return None
    try:
        return max(hits, key=os.path.getmtime)
    except OSError:
        # ⛔ A HIT THAT VANISHED BETWEEN THE GLOB AND THE STAT IS "NOT FOUND", NOT A CRASH. The glob
        # proves a name existed a moment ago, not that it is still stat-able: a rotated/removed session
        # file raises FileNotFoundError HERE, one call BEFORE `collect()`'s guard — so without this it
        # still escaped `main()` as rc 1 with empty stdout, the code the `3 UNMEASURED` contract
        # retires. `None` is the same answer the caller already handles as "no session file".
        return None


def turns(path, want):
    """The last `want` assistant turns, oldest first."""
    got = []
    for line in open(path, errors="ignore"):
        try:
            o = json.loads(line)
        except Exception:
            continue
        # ⛔ A LINE THAT PARSES TO A NON-OBJECT IS SKIPPED, NOT A CRASH. `null`, `5`, `[]`, `"x"` all
        # parse cleanly and then raise AttributeError from `.get()` — which is NOT an OSError, so it
        # escaped both this function's own "tolerate an unparseable line" stance and `collect()`'s
        # guard, and killed the process with rc 1 and empty stdout.
        if not isinstance(o, dict):
            continue
        msg = o.get("message") if isinstance(o.get("message"), dict) else o
        if (msg or {}).get("role") != "assistant":
            continue
        c = msg.get("content")
        if isinstance(c, str):
            txt = c
        elif isinstance(c, list):
            # ⛔ `str(...)` IS THE GUARD, NOT TIDINESS: a text block whose `"text"` is `null` or a
            # NUMBER raises `TypeError: sequence item 0: expected str instance, NoneType/in found` out
            # of `join` — not an OSError, so it escaped `collect()`'s guard to rc 1 and empty stdout.
            txt = " ".join(str(x.get("text") or "") for x in c
                           if isinstance(x, dict) and x.get("type") == "text")
        else:
            txt = ""
        if txt.strip():
            got.append(" ".join(txt.split()))
    return got[-want:]


def collect(key, chars=400, want=1):
    """The payload, built ONCE for both surfaces (text and `--json`).

    Returns ``(rc, payload)``. `rc` is the exit contract in the module docstring; `payload` always
    carries `measured_at` and, on a failure, a named `unmeasured` — so the JSON and the prose can never
    disagree about which outcome happened (the defect #3382 exists to remove, in miniature).
    """
    rows = lane_rows()
    now = int(time.time())
    base = {"measured_at": now, "lane_key": key}
    if rows is None:
        return 3, dict(base, unmeasured=(
            "UNMEASURED(lane-status.py --json --sample 2 + no parseable rows: the lane table could "
            "not be read, so this lane's activity is unknown)"))
    # ⛔ EVERY ROW IS A `dict` IN PRACTICE AND NOT BY CONTRACT: `lane_rows()` only checks that the
    # payload is a LIST, so a `null`/`"WS1"`/`[]` element makes `.get()` raise AttributeError here —
    # the same non-OSError escape the line-level guard below closes, one layer up. A row that is not an
    # object cannot match a lane, so it is skipped rather than trusted.
    row = next((r for r in rows if isinstance(r, dict)
                and (str(r.get("ws", "")).upper() == key
                     or str(r.get("lane", "")).upper() == key)), None)
    if not row:
        return 2, dict(base, unmeasured=None,
                       note="no lane matches %r — run lane-status.py for the list" % key)
    sid, verdict = row.get("sid"), row.get("verdict")
    path = session_file(sid)
    if not path:
        return 3, dict(base, lane=row.get("lane"), ws=row.get("ws"), sid=sid, verdict=verdict,
                       unmeasured=("UNMEASURED(session file for sid %s + not found under %s: the "
                                   "lane's activity cannot be read, so it is NOT known idle)"
                                   % (str(sid)[:8] or "<none>", SESS)))
    # ⛔ A PRESENT-BUT-UNREADABLE SESSION FILE IS STILL `3`, NOT A CRASH. `session_file()` proves the
    # path EXISTS; it does not prove it can be READ. `getmtime()`/`open()` on a file owned by another
    # user, rotated away between the glob and the open, or a DIRECTORY matching the glob raised out of
    # `collect()`, out of `main()`, and the process died with rc=**1** and empty stdout — the one code
    # this contract retires, on exactly the path its own justification names ("the lane matched but its
    # activity could NOT be read"). Measured before this guard: `IsADirectoryError` from `turns()`, and
    # `PermissionError`/`FileNotFoundError` from the `getmtime()` above.
    try:
        age_m = (time.time() - os.path.getmtime(path)) / 60.0
        turns_read = turns(path, want)
    except OSError as exc:
        return 3, dict(base, lane=row.get("lane"), ws=row.get("ws"), sid=sid, verdict=verdict,
                       session_file=path,
                       unmeasured=("UNMEASURED(session file %s + unreadable: %s — the lane's activity "
                                   "cannot be read, so it is NOT known idle)"
                                   % (path, exc.strerror or exc.__class__.__name__)))
    # ⛔ THE TRUNCATION MARKER IS APPLIED HERE, ONCE, so the prose and the JSON cannot disagree —
    # the contract this payload exists to keep. The rewrite that introduced `collect()` dropped the
    # `("…" if len(t) > chars)` the prose branch used to carry, so an operator could no longer tell a
    # truncated turn from a complete one: the ONE thing `--chars` exists to make unambiguous.
    # ⛔ AND `turns_truncated` NOW MEANS WHAT IT SAYS. It used to be set to `want` — the REQUESTED
    # turn count — so a machine consumer reading it as a truncation flag was wrong on every call.
    # The requested count is reported, correctly named, as `turns_requested`.
    shown = [t[:chars] + ("\u2026" if len(t) > chars else "") for t in turns_read]
    return 0, dict(base, lane=row.get("lane"), ws=row.get("ws"), sid=sid, verdict=verdict,
                   session_file=path, session_age_m=round(age_m, 1),
                   turns=shown,
                   turns_requested=want,
                   turns_truncated=any(len(t) > chars for t in turns_read),
                   chars=chars,
                   route=("unfinished -> nudge it to CONTINUE that work; "
                          "finished -> hand it the next unheld item; "
                          "a question -> route it (ask-owner.py)"))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__.split("Usage:")[1].strip()); return 2
    key = args[0].upper()
    chars = 400
    want = 1
    as_json = "--json" in sys.argv[1:]
    # ⛔ A BAD `--chars`/`--turns` VALUE IS A USAGE ERROR (2), NOT A TRACEBACK. `int()` raises
    # ValueError — not an OSError — so `--chars abc` (or `--chars --json`, where the flag is taken as
    # the value) killed the process with rc 1 and EMPTY stdout: the code this module's contract says
    # must never occur, produced by a caller typo rather than by an unreadable lane.
    for i, a in enumerate(sys.argv):
        if a == "--chars" and i + 1 < len(sys.argv):
            try:
                chars = int(sys.argv[i + 1])
            except (TypeError, ValueError):
                sys.stderr.write("lane-wip: --chars needs an integer, got %r\n" % (sys.argv[i + 1],))
                return 2
        if a == "--turns" and i + 1 < len(sys.argv):
            try:
                want = int(sys.argv[i + 1])
            except (TypeError, ValueError):
                sys.stderr.write("lane-wip: --turns needs an integer, got %r\n" % (sys.argv[i + 1],))
                return 2

    rc, payload = collect(key, chars=chars, want=want)
    if as_json:
        print(json.dumps(payload, indent=2, sort_keys=True, default=str))
        return rc
    if rc == 3:
        print(payload["unmeasured"])
        return rc
    if rc == 2:
        print(payload["note"])
        return rc
    print(f"LANE    {payload.get('lane')}")
    print(f"VERDICT {payload.get('verdict')}   session written {payload.get('session_age_m'):.0f}m ago"
          f"   (id {str(payload.get('sid'))[:8]})")
    print(f"WS      {payload.get('ws')}")
    print()
    print("LAST TURN" + ("S (oldest first)" if want > 1 else "") + ":")
    for t in payload["turns"]:
        print("  " + t)
    print()
    print("ROUTE ON THE ABOVE — not on the verdict:")
    print("  unfinished  -> nudge it to CONTINUE that work, naming it")
    print("  finished    -> hand it the next unheld item for its lane")
    print("  a question  -> route it (ask-owner.py); do not answer it here")
    return 0


if __name__ == "__main__":
    sys.exit(main())
