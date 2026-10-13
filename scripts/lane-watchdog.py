#!/usr/bin/env python3
"""lane-watchdog — unstick a lane whose child dispatch is FROZEN, and never a lane that is working.

WHY THIS EXISTS
───────────────
A `task`/`subagent` dispatch spawns child `pi` processes. Measured 2026-10-12: a parallel
`subagent` round spawned three children, all three sat in `Ss` with a CPU delta of LITERALLY ZERO
over 30s and never wrote a transcript, and the parent waited on them for **2h28m** while its own
process stayed alive and burned CPU. `TERM` on those three children returned the call immediately
(`Parallel: 0/3 succeeded`) and the parent resumed in the same second. The consumer was the
ORCHESTRATOR — the lane whose throughput IS the dispatch queue.

The hang is invisible to every other probe in the fleet: the lane's process is alive, its CPU is
advancing, there is no error, and no watchdog covers it (`TASK_STREAM_STALL_MS` bounds the builtin
`task` tool, not this path). So it must be detected here.

⛔ THE THREE GATES — ALL REQUIRED, AND A RAPER THAT SKIPS ONE IS A LANE-KILLER
─────────────────────────────────────────────────────────────────────────────
A child that is legitimately busy is indistinguishable from a frozen one by any SINGLE signal:

  1. **ZERO CPU DELTA**, with the tolerance STATED (`CPU_TOL`) — because a sub-0.1s twitch has the
     same signature from a parked fork child, a human's prompt redraw, and a timer wake. Measured
     over a real window (`WINDOW`), never one sample.
  2. **ANCESTRY WALKED TO THE TOP** — any `Terminal.app` / `iTerm` / login-shell ancestor means the
     process belongs to a HUMAN, and it is never touched however parked it looks. `ppid 1` proves
     nothing on its own: a daemonising service reparents to 1 BY DESIGN.
  3. **PROGRESS vs ITS OWN EXPECTED DISTRIBUTION** — the process must be older than `MIN_AGE`, and
     the subtree must be frozen ACROSS TICKS (see `FROZEN_TICKS`), not merely at one instant.

If either read is unclear: REPORT, DO NOT REAP.

⛔ AND IT REAPS THE CHILD, NEVER THE LANE. The lane's own `pi` holds the conversation and its
context; killing it destroys the lane's work. The frozen offspring hold nothing — they are the
thing that is stuck. Reaping them is what makes the parent's tool call RETURN.

⛔ WHY "FROZEN ACROSS TICKS" AND NOT A SINGLE WINDOW. A child in a long model call sits at zero
CPU with no transcript growth for minutes — which is exactly the frozen signature. One window
cannot tell them apart, so a candidate must be seen frozen on `FROZEN_TICKS` consecutive runs
spanning `FROZEN_MIN` seconds before it is touched. A pathological multi-tick zero-CPU model call
is already past the harness's own 20-minute stall bound, so bounding our action there is
consistent with the bound the fleet already uses.
"""
import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time

CPU_TOL = 0.1        # seconds of CPU a subtree may gain across WINDOW and still count as frozen
WINDOW = 30          # seconds between the two CPU samples
MIN_AGE = 600        # a child must have existed this long before it can be reaped
FROZEN_TICKS = 2     # consecutive runs a candidate must be frozen
# ⛔ 1800, NOT 900, AND IT MUST EXCEED THE HARNESS'S OWN STALL BOUND (TASK_STREAM_STALL_MS default
# 1200000ms = 1200s). The docstring used to justify 900s as "already past the harness's own
# 20-minute bound" -- it was not, and the effective floor was lower still because the frozen clock
# started DURING the MIN_AGE window (min ~15.5 min). A bound that undercuts the one the fleet
# already uses cannot be justified by that fleet's rule.
FROZEN_MIN = 1800    # ... spanning at least this long
LOG = os.path.expanduser("~/.pi/agent/state/lane-watchdog.jsonl")
LOCK = os.path.expanduser("~/.pi/agent/state/lane-watchdog.lock")
STATE = os.path.expanduser("~/.pi/agent/state/lane-watchdog.candidates.json")

# ⛔ THE BOUNDARY, NOT A MARKER ANYWHERE IN THE CHAIN. Both the owner's shell AND every fleet lane
# run through `login` + `-zsh`; what separates them is which terminal the chain hangs off.
# MEASURED 2026-10-12 (this box), a lane's real chain:
#   pi -> -/bin/zsh -> /usr/bin/login -flp ... -> /Applications/cmux.app/Contents/MacOS/cmux
# So treating ANY `login`/`zsh` as human refuses EVERY lane (safe, and a no-op), while treating
# none as human reaps into the owner's terminal. Walked NEAREST-FIRST: a human terminal ends it as
# human; the fleet harness ends it as ours.
FLEET_MARKERS = ("cmux.app", "cmux")
HUMAN_MARKERS = ("terminal.app", "iterm")


def cpu_seconds(tok):
    """`ps` TIME ([[dd-]hh:]mm:ss.ss) -> float seconds."""
    try:
        days = 0
        if "-" in tok:
            d, _, tok = tok.partition("-")
            days = int(d)
        parts = [float(p) for p in tok.split(":")]
        s = 0.0
        for p in parts:
            s = s * 60 + p
        return s + days * 86400
    except Exception:
        return 0.0


def ps_table():
    """{pid: dict(ppid, stat, cpu, cmd)} for every process, one snapshot."""
    try:
        out = subprocess.run(["ps", "-Ao", "pid=,ppid=,stat=,time=,command=", "-ww"],
                             capture_output=True, text=True, timeout=60).stdout
    except Exception:
        return {}
    table = {}
    for line in out.splitlines():
        f = line.split(None, 4)
        if len(f) < 5:
            continue
        try:
            pid = int(f[0])
        except ValueError:
            continue
        table[pid] = dict(ppid=int(f[1]), stat=f[2], cpu=cpu_seconds(f[3]), cmd=f[4])
    return table


def descendants(root, table):
    """Every descendant pid of `root`, parents before children.

    ⛔ A `seen` SET, like `ancestry()`. A table containing a ppid cycle made this loop forever -- and
    a hung run holds the flock for the life of the process, so every later run exits `skipped` and
    the guard dies silently. No cycle is known to occur in a real `ps` table; this is hardening.
    """
    kids = {}
    for pid, r in table.items():
        kids.setdefault(r["ppid"], []).append(pid)
    out, seen, stack = [], {root}, list(kids.get(root, []))
    while stack:
        pid = stack.pop(0)
        if pid in seen:
            continue
        seen.add(pid)
        out.append(pid)
        stack.extend(kids.get(pid, []))
    return out


def is_pi(r):
    """A `pi` process, by the argv it rewrites itself to.

    Compares the FIRST argv word's basename, not the whole line: `cmd.endswith("/pi")` also matches
    `grep -n foo /pi` and any other command whose last argument happens to be a `/pi` path.
    """
    cmd = r["cmd"].strip()
    if not cmd:
        return False
    first = cmd.split()[0]
    return os.path.basename(first) == "pi"


def has_live_connection(pid):
    """True / False / None(unknown): does `pid` hold an ESTABLISHED TCP connection?

    ⛔ THE ONE POSITIVE LIVENESS SIGNAL THAT SURVIVES A LONG MODEL CALL. Every other gate here is
    the ABSENCE of something (no CPU, no descendants, no transcript growth), and an adversarial
    review on 2026-10-12 measured a WORKING `task` child sitting exactly on that shape -- zero
    descendants, subΔCPU 0.00 -- excluded only by a 0.44s CPU reading. A live provider call HOLDS AN
    ESTABLISHED CONNECTION (`42029 -> 3.173.21.63:443 ESTABLISHED` was measured), and the two
    genuinely-wedged children held NONE, in every sample.

    ⛔ UNKNOWN REFUSES. lsof failing or timing out is NOT evidence of no connection; every other
    unclear read in this file abstains, and this one authorises a kill.
    """
    try:
        r = subprocess.run(
            ["lsof", "-n", "-P", "-a", "-p", str(pid), "-i", "-sTCP:ESTABLISHED"],
            capture_output=True, text=True, timeout=30)
    except Exception:
        return None
    # ⛔ `FOUND NOTHING` IS NOT THE SAME AS `FAILED`, AND ONLY ONE OF THEM IS AN ANSWER (2026-10-13).
    # The body read `bool(out.strip())`, so an lsof that FAILED while printing nothing returned
    # False — and False is the value that puts a child in the REAP SET. The docstring above states
    # the contract and the body broke it. ⛔ MEASURED ON THIS HOST (lsof 4.91), because the first
    # cut of this fix got the polarity INVERTED: a dead pid AND a live pid with no established TCP
    # BOTH exit **1** with EMPTY stdout AND EMPTY stderr, while a genuine failure (an illegal
    # option; likewise a missing binary, which raises) exits 1 but WRITES TO STDERR. So a bare
    # `rc != 0 -> None` would have made this reaper permanently INERT — every child unknown, nothing
    # ever reapable. The discriminator is therefore the SILENCE ON BOTH STREAMS, not the exit code.
    if r.returncode == 0 and r.stdout.strip():
        return True                     # a clean read that FOUND an established connection
    if r.returncode == 1 and not r.stdout.strip() and not r.stderr.strip():
        return False                    # lsof ran fine and located nothing: a genuine "no connection"
    return None                         # failed, timed out, or spoke up: UNKNOWN, and UNKNOWN refuses


def frozen_subtrees(table_a, table_b, now=None):
    """Every `pi` child of a `pi` parent whose whole subtree gained no CPU across the window.

    Returns a list of `dict(pid, ppid, age_s, d_cpu)`. This is the DETECTOR only — it decides
    nothing; `evaluate()` applies the gates and `reap()` acts.
    """
    now = now or time.time()
    out = []
    for pid, b in table_b.items():
        a = table_a.get(pid)
        if not a:
            continue                                   # born during the window: too new to judge
        if not is_pi(b):
            continue                                   # only dispatched children, never a wrapper
        parent = table_b.get(b["ppid"])
        if not parent or not is_pi(parent):
            continue                                   # a lane's own pi is never a candidate
        subtree = [pid] + descendants(pid, table_b)
        d = 0.0
        for q in subtree:
            if q in table_a:
                d += max(0.0, table_b[q]["cpu"] - table_a[q]["cpu"])
        if d > CPU_TOL:
            continue
        # ⛔ ONLY `pi` MAY BE UNDER A CANDIDATE -- NOT "NO SHELL". A TOOL CALL IS NOT A HANG, AND
        # THE FIRST ATTEMPT AT THIS RULE WAS WRONG. It rejected candidates with a SHELL descendant,
        # on the theory that a tool call lives under a shell. It does not survive: bash `exec`s a
        # SINGLE SIMPLE COMMAND, so `bash -c "gh run watch 123"` leaves NO shell in the tree -- the
        # poller IS the descendant. And it inverts on the very case it was written for:
        # `gh run watch`, `npm ci`, `docker build`, `sleep 1800` are all one command, so all four
        # passed the shell gate, and an adversarial review then ran this function against the live
        # process table and found IT HAD FLAGGED ITS OWN REVIEWING SESSION (a pi whose tool shell
        # had exec'd into its command).
        #
        # The structural rule that IS true of a tool call and false of the measured orphan: a tool
        # call always leaves a NON-`pi` process under the child (the command bash exec'd into),
        # while the orphan had NO descendants at all. So a candidate may only have `pi` under it.
        # This is strictly narrower than the shell rule, which is the safe direction here.
        if any(not is_pi(table_b[q]) for q in subtree[1:]):
            continue
        # ⛔ AN ESTABLISHED CONNECTION IS LIVENESS — AND THE GATE MUST COVER THE WHOLE SUBTREE, NOT
        # JUST THE ROOT (2026-10-13). `reap()` signals EVERY pid in `subtree`, while this gate asked
        # only about `pid`. A nested dispatch (`pi -> pi`, explicitly permitted by the `is_pi` rule
        # above) is therefore reachable in exactly the shape the gate exists to spare: a PARKED
        # middle `pi` whose GRANDCHILD holds the provider connection. Measured by review: candidates
        # `[(200, [200, 300])]` with 300 holding an ESTABLISHED connection — 300 was correctly
        # excluded as its own candidate, and was then dragged into 200's kill list anyway.
        if any(has_live_connection(q) is not False for q in subtree):
            continue
        # The whole subtree is parked. `age_s` comes from the child's own process age.
        out.append(dict(pid=pid, ppid=b["ppid"], age_s=_age_seconds(pid, table_b),
                        d_cpu=round(d, 3), subtree=subtree))
    return out


def _age_seconds(pid, table):
    try:
        o = subprocess.run(["ps", "-o", "etime=", "-p", str(pid)],
                           capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception:
        return None
    if not o:
        return None
    days = 0
    if "-" in o:
        d, _, o = o.partition("-")
        days = int(d)
    parts = o.split(":")
    try:
        parts = [int(p) for p in parts]
    except ValueError:
        return None
    s = 0
    for p in parts:
        s = s * 60 + p
    return s + days * 86400


def ancestry(pid, table):
    """The ancestor chain, nearest first, as `[(pid, cmd), ...]`. Bounded to stop a cycle looping."""
    chain, seen = [], set()
    cur = pid
    for _ in range(64):
        r = table.get(cur)
        if not r or cur in seen:
            break
        seen.add(cur)
        chain.append((cur, r["cmd"]))
        cur = r["ppid"]
        if r["ppid"] in (0, 1):
            # include pid 1 so the top of the chain is visible, then stop
            if r["ppid"] in table:
                r1 = table[r["ppid"]]
                chain.append((r["ppid"], r1["cmd"]))
            break
    return chain


def human_above(pid, table):
    """GATE 2. True unless the chain provably passes through the fleet harness.

    Walked TO THE TOP and reported, never inferred from `ppid == 1` -- a daemonising service
    reparents to 1 by design, so a chain that reaches 1 through cmux is fine while a chain that
    reaches 1 through a login shell is the owner's own terminal.

    ⛔ THE DEFAULT IS REFUSE (`return True`). A chain with neither a human terminal nor cmux is one
    we cannot prove is ours, and an unproven target is REPORTED, never reaped.
    """
    for _, cmd in ancestry(pid, table):
        low = cmd.lower()
        if any(m in low for m in HUMAN_MARKERS):
            return True
        if any(m in low for m in FLEET_MARKERS):
            return False
    return True


# ⛔ WHY LANE SILENCE IS *NOT* A GATE.
# It is the obvious trigger and the wrong one. It is EXPENSIVE -- resolving each workspace's session
# costs one cmux round trip per lane, which disqualifies it from a per-tick path. More importantly it
# is the WRONG QUESTION: a lane is legitimately silent for hours inside a long tool call or a merge
# rail (Drain spent one at 32% CPU), so a silent lane authorises nothing. What authorises a reap is
# that a DISPATCHED CHILD's subtree has been provably inert across ticks.


def evaluate(cands, table, state, now=None, min_age=MIN_AGE):
    """Apply the gates and merge with persisted observations.

    Returns `(ripe, watching, refused, ticks)`: the candidates frozen long enough to act on, those
    still accruing evidence, and those refused by a gate with the reason.

    ⛔ A CANDIDATE'S SUBTREE MUST NOT HAVE CHANGED COMPOSITION BETWEEN TICKS -- but that rule ALONE
    IS NOT ENOUGH, and believing it was is how a P0 shipped. `sleep 180 && gh run view ...` is a
    zero-CPU subtree by construction, and a SINGLE long-lived poller (`gh run watch`, `npm ci`,
    `docker build`, `sleep 1800`) holds a STABLE pid set for its whole run -- so composition says
    nothing about those. The rule that actually separates work from a hang is in `frozen_subtrees`
    (only `pi` may sit under a candidate) plus the ESTABLISHED-connection check in this module;
    composition is a supporting signal, not the discriminator. A change RESETS the clock.
    """
    now = now or time.time()
    ripe, watching, refused = [], [], []
    seen = {}
    meta = {}
    for c in cands:
        pid = c["pid"]
        if human_above(pid, table):
            refused.append(dict(pid=pid, reason="HUMAN ANCESTOR -- belongs to the owner's terminal"))
            continue
        sub = sorted(c["subtree"])
        prev = state.get(str(pid), {})
        first = prev.get("first_seen")
        birth = (now - c["age_s"]) if c["age_s"] is not None else None
        # ⛔ A RECYCLED PID IS A DIFFERENT PROCESS. The observation is keyed by pid alone, so a pid
        # that died and was reused inside one tick gap inherited the dead process's `first_seen` --
        # an adversarial review measured a 601-second-old process ripening on its FIRST observation
        # with `frozen_for: 259200` taken from a three-day-old row. `birth` (now - age) must match.
        prev_birth = prev.get("birth")
        recycled = (prev_birth is not None and birth is not None
                    and abs(prev_birth - birth) > 60)
        # ⛔ BIRTH AND `recycled` ARE PER-PID, NOT PER-RUN (2026-10-13). Both were bound in THIS
        # loop and then read again in the separate persistence loop below, so every entry carried
        # the LAST candidate's values — poisoning the recycle baseline for every other pid. A
        # sibling child spawned in the same parallel `task` round is born within seconds of its
        # peers, i.e. precisely close enough to mask a recycle, so a genuinely reused pid could
        # inherit the dead process's `first_seen` and ripen on a three-day-old clock. Measured by
        # review: `birth[300]` persisted as 1999300.0 (its true value was 1995000.0). The single-
        # candidate test could not see it. Keep them paired with the pid they belong to.
        meta[pid] = (birth, recycled)
        if recycled:
            first = None
            watching.append(dict(pid=pid, age_s=c["age_s"],
                                 reason="pid was recycled -- this is a different process"))
        if prev.get("subtree") is not None and prev.get("subtree") != sub:
            first = None
            watching.append(dict(pid=pid, age_s=c["age_s"],
                                 reason="subtree composition changed -- it is doing something"))
        if c["age_s"] is None:
            # ⛔ AN UNREADABLE AGE MUST REFUSE RATHER THAN BE COMPARED. `_age_seconds()` returns None
            # when its `ps` read fails, and `None < min_age` does not evaluate to False in Python 3 —
            # it RAISES TypeError. ⚠️ CORRECTED 2026-10-13: this comment claimed the comparison was
            # "False when age is None, so MIN_AGE was bypassed entirely and the candidate ripened at
            # +1800s". The first half is wrong (`python3 -c "print(None < 300)"` -> TypeError), and
            # `evaluate()` is called with no surrounding try/except, so the unguarded path would have
            # ABORTED the whole run, not silently ripened anything. No committed state of this file
            # ever contained that bypass. The guard is still required — a failed `ps` must abstain —
            # but its real effect is "turn a crash into an abstention", which is the honest reason.
            watching.append(dict(pid=pid, age_s=None, reason="age unreadable -- refusing to judge"))
            continue
        if c["age_s"] < min_age:
            # ⛔ THE CLOCK DOES NOT START UNTIL THE CHILD IS OLD ENOUGH. Starting it here measured
            # frozen time from the FIRST OBSERVATION, so the effective floor was MIN_AGE - (tick
            # spacing) + FROZEN_MIN instead of MIN_AGE + FROZEN_MIN -- as low as ~930s, below the
            # harness bound the threshold cites. A young candidate accrues NOTHING.
            watching.append(dict(pid=pid, age_s=c["age_s"],
                                 reason=f"too young (<{min_age}s)"))
            continue
        if first is None:
            first = now
            watching.append(dict(pid=pid, age_s=c["age_s"],
                                 reason=f"first observation; needs {FROZEN_TICKS} ticks / "
                                        f"{FROZEN_MIN}s frozen"))
        else:
            frozen_for = int(now - first)
            ticks_n = prev.get("ticks", 1) + 1
            if ticks_n >= FROZEN_TICKS and frozen_for >= FROZEN_MIN:
                ripe.append(dict(c, first_seen=first, frozen_for=frozen_for, ticks=ticks_n))
                seen[pid] = first
                continue
            watching.append(dict(pid=pid, age_s=c["age_s"],
                                 reason=f"frozen {frozen_for}s across {ticks_n} ticks; needs "
                                        f"{FROZEN_TICKS} ticks / {FROZEN_MIN}s"))
        seen[pid] = first
    # persist the observation log for the next tick (this is what makes "across ticks" possible)
    ticks = {}
    for pid, first in seen.items():
        prev = state.get(str(pid), {})
        sub = sorted(next((c["subtree"] for c in cands if c["pid"] == pid), []))
        # a composition change must reset the TICK count too, or "N runs" is not really N runs
        changed = prev.get("subtree") is not None and prev.get("subtree") != sub
        birth, recycled = meta.get(pid, (None, False))
        ticks[str(pid)] = dict(first_seen=first,
                               ticks=1 if changed or recycled else prev.get("ticks", 0) + 1,
                               last_seen=now, ppid=table.get(pid, {}).get("ppid"),
                               subtree=sub, birth=birth)
    return ripe, watching, refused, ticks


def reap(cand, table_a, table_b, ts):
    """GATE passed -> TERM the frozen subtree, child first, and report what happened.

    The parent is never signalled: its context is the lane's work, and the whole point is to make
    its tool call RETURN, which terminating the offspring does.
    """
    killed = []
    # children before parents, so nothing is reparented mid-kill
    for pid in sorted(cand["subtree"], key=lambda p: -len(ancestry(p, table_b))):
        try:
            os.kill(pid, signal.SIGTERM)
            killed.append(pid)
        except ProcessLookupError:
            pass
        except Exception as e:
            return dict(pid=cand["pid"], ended=False, killed=killed, error=str(e))
    return dict(pid=cand["pid"], ended=True, killed=killed, parent=cand["ppid"])


def acquire_lock():
    """Hold the single-run lock, or return None when another run already holds it.

    ⛔ REQUIRED, NOT A NICETY. The tick may launch this detached on consecutive passes, and the
    "frozen ACROSS TICKS" rule is exactly what two concurrent runs would corrupt: both would read
    the same state file, both would see `first_seen` from the other, and a candidate could reach
    `FROZEN_TICKS` in seconds instead of minutes -- collapsing the gate that separates a stuck child
    from one in a long model call. The lock is held for the whole run, so even a killed run's lock
    is released by the kernel.
    """
    try:
        import fcntl
    except ImportError:
        # ⛔ REFUSE, DO NOT PROCEED. An unprovable lock must not authorise a KILL: two concurrent
        # runs double-count each other's ticks, and that is the gate that separates a stuck child
        # from one in a long model call. Returning True here was fail-open on the one mechanism the
        # docstring calls "REQUIRED, NOT A NICETY" -- for a process-killer the safe direction is to
        # do nothing.
        return None
    try:
        os.makedirs(os.path.dirname(LOCK), exist_ok=True)
        fh = open(LOCK, "w")
    except Exception:
        return None
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return None
    return fh


def main():
    ap = argparse.ArgumentParser(description="unstick lanes whose child dispatch is FROZEN")
    ap.add_argument("--json", action="store_true", help="machine-readable report")
    ap.add_argument("--apply", action="store_true",
                    help="actually signal. WITHOUT this it is a dry run, and a dry run is the "
                         "default because the action is a kill.")
    ap.add_argument("--window", type=int, default=WINDOW)
    ap.add_argument("--min-age", type=int, default=MIN_AGE)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    hold = acquire_lock()
    if hold is None:
        # Another run owns the observation state; observe nothing rather than double-count ticks.
        if args.json:
            print(json.dumps(dict(skipped="another run holds the lock")))
        return 0

    a = ps_table()
    time.sleep(args.window)
    b = ps_table()
    cands = frozen_subtrees(a, b)

    try:
        state = json.load(open(STATE))
    except Exception:
        state = {}

    ripe, watching, refused, ticks = evaluate(cands, b, state, min_age=args.min_age)

    report = dict(observed=len(b), frozen=len(cands), ripe=len(ripe),
                  watching=watching, refused=refused, reaped=[], ts=int(time.time()))

    if args.apply and ripe:
        for c in ripe:
            res = reap(c, a, b, report["ts"])
            report["reaped"].append(res)
            _log(dict(event="reap", ts=report["ts"], **res,
                      d_cpu=c["d_cpu"], age_s=c["age_s"], frozen_for=c["frozen_for"]))
    elif ripe:
        _log(dict(event="reap-dry-run", ts=report["ts"],
                  pids=[c["pid"] for c in ripe]))

    # only keep observations for processes that still exist, so the file cannot grow forever
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    alive = {p: v for p, v in ticks.items() if int(p) in b}
    try:
        json.dump(alive, open(STATE, "w"), indent=1)
    except Exception:
        pass

    if args.json:
        print(json.dumps(report, indent=1))
    elif not args.quiet:
        print(f"observed={report['observed']} frozen={report['frozen']} ripe={report['ripe']} "
              f"reaped={len(report['reaped'])}")
        for c in ripe:
            print(f"  RIPE pid={c['pid']} ppid={c['ppid']} age={c['age_s']}s "
                  f"frozen={c['frozen_for']}s dCPU={c['d_cpu']}")
        for c in watching:
            print(f"  watch pid={c['pid']} age={c.get('age_s')}s -- {c['reason']}")
        for c in refused:
            print(f"  REFUSED pid={c['pid']} -- {c['reason']}")
    return 0


def _log(row):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write(json.dumps(row) + "\n")
    except Exception:
        pass


if __name__ == "__main__":
    sys.exit(main())
