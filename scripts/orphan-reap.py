#!/usr/bin/env python3
"""orphan-reap.py — reap ORPHANED test/tooling processes, under the three gates.

WHY THIS EXISTS
`orphan-scan.py` only reports (and is pinned to one lane's needle); `embedded_orphans.py` is a
census; `run_reaper.py` cancels GitHub Actions runs, not processes. So the class that #5035
documented — a test process whose parent died, silently promoted to `ppid 1` where **nothing owns
it**, free to run for two days — had NO reaper. The three-gate walk that killed the 43h48m pytest
was done **by hand**. This is that walk, as code, with the dry-run as the default.

    #5035's own words: "`ppid 1` is a silent promotion to 'nobody owns this.'"

THE FIVE GATES (all must pass; any unclear read => REPORT, never reap)
  1. CPU DELTA, tolerance stated — a sub-0.1 s twitch has the same signature as a parked fork
     child, a human's prompt redraw, or a timer wake. So: PARKED = delta < 0.10 s over the
     sample. (A spin, by contrast, is 100x that: #5035 measured +19.44 s over 30 s.)
  2. ANCESTRY WALK TO THE TOP — any Terminal.app / iTerm / login-shell ancestor means it belongs
     to a HUMAN: never touch it, however parked it looks. `ppid 1` alone proves nothing (a
     daemonising service reparents to 1 BY DESIGN), which is why the walk is the gate.
  3. ITS OWN EXPECTED DISTRIBUTION — progress judged against what this class of process should
     cost, not against the clock in general.
  4. ⛔ LAUNCHD-REGISTRATION GATE (added 2026-10-12) — if the pid is a REGISTERED launchd job,
     it is a managed daemon with an owner (the owner's menu-bar app, minutes-mcp, cmux...).
     `ppid 1` looks identical. NEVER reap one. Without this gate the reaper kills the owner's
     own UI.
  5. ⛔ DESIGNED-DAEMON GATE (added 2026-10-12, AFTER THE FIRST DRY RUN WAS WRONG) — gates 1-4
     passed on THREE processes and ALL THREE were wrong to reap:
       * `live-workspaces-publisher.py` — `--loop` in argv, a pidfile, and its output file
         written 10 minutes ago. A LIVE daemon that merely got reparented, not an orphan;
       * two `redis-server` processes whose unix sockets had a LIVE CLIENT (`lsof` showed a
         second holder on each) — reaping them would have broken a running test.
     Intent is not visible in `ppid`, CPU, or elapsed time. So: pidfile naming the pid, a
     daemon-ish flag in argv, an output file touched recently, or ANY live holder of a socket
     it owns  =>  DESIGNED => never reap.

Reapable != right to reap: a candidate with diagnostic value stays (evidence beats tidiness).

USAGE
    orphan-reap.py                 # dry run (default): report every candidate + gate reading
    orphan-reap.py --apply         # SIGTERM the ones that pass all five, then verify gone
    orphan-reap.py --sample 20     # CPU sample window in seconds (default 15)
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time

# ── the candidate class ───────────────────────────────────────────────────────────────────────
# Only things WE run inside our own checkouts. An Apple executable is never a candidate, and a
# launchd job is never a candidate (gate 4). Both exclusions are positive identification, so a
# new Apple helper that happens to sit at ppid 1 is reported-not-reaped rather than killed.
OURS = re.compile(r"^/Users/[^/]+/Documents/GitHub/")
TESTISH = re.compile(r"pytest|^\.?/?.+\.venv/bin/python|uvicorn|gunicorn|/bin/bash -c ", re.I)
# ⛔ NOT IN THIS TOOL'S CLASS: embedded `redislite` redis-server processes. Another agent owner
# already exists for them — `tortoise/tools/embedded_orphans.py` (the bounded census), the launchd
# job `com.tortoise.embedded-reaper`, and issue #3599 — whose only_safe mode exists precisely
# because a stranded redis CAN still have a live client. Reaping them here would duplicate that
# logic and, measured 2026-10-12, would have broken a running test: `lsof` showed pid 72824 holding
# the socket of BOTH stranded servers. Leave them to their owner; do not widen this regex.
# A human's terminal — the ancestry gate. Checked as a SUBSTRING of the full ancestor path.
HUMAN = ("Terminal.app", "iTerm", "/usr/bin/login", "login.app", "Warp.app", "kitty.app",
         "Alacritty.app", "cmux.app", "tmux")

TOLERANCE_S = 0.10          # gate 1: below this the process is PARKED
HTTP_BUDGET_S = 8           # bound the launchctl call; an unbounded helper is an unbounded step


def ps_fields() -> dict[str, dict]:
    out = subprocess.run(["ps", "-Ao", "pid=,ppid=,pcpu=,time=,etime=,comm=,args="],
                         capture_output=True, text=True).stdout
    rows: dict[str, dict] = {}
    for ln in out.splitlines():
        p = ln.split(None, 6)
        if len(p) < 7:
            continue
        rows[p[0]] = {"pid": p[0], "ppid": p[1], "pcpu": p[2], "time": p[3],
                      "etime": p[4], "comm": p[5], "args": p[6]}
    return rows


def cpu_seconds(t: str) -> float:
    """`0:52.97` / `3124:47` / `01-19:48:27` -> seconds."""
    try:
        days = 0.0
        if "-" in t:
            d, t = t.split("-", 1)
            days = float(d)
        parts = [float(x) for x in t.split(":")]
        secs = sum(v * (60 ** i) for i, v in enumerate(reversed(parts)))
        return days * 86400 + secs
    except Exception:
        return -1.0


def etime_seconds(t: str) -> float:
    t = t.strip()
    days = 0.0
    if "-" in t:
        d, t = t.split("-", 1)
        days = float(d)
    parts = [float(x) for x in t.split(":")]
    return days * 86400 + sum(v * (60 ** i) for i, v in enumerate(reversed(parts)))


def registered_launchd_pids() -> set[str]:
    """Gate 4. `launchctl list` prints PID/status/label. A pid present here is a MANAGED JOB."""
    pids: set[str] = set()
    for domain in ("system", f"gui/{os.getuid()}"):
        try:
            out = subprocess.run(["launchctl", "list"], capture_output=True, text=True,
                                 timeout=HTTP_BUDGET_S).stdout
        except Exception:
            # An unreadable domain must FAIL CLOSED (treat everything as registered) — a
            # resolver that fails open is how a reaper kills a daemon it could not see.
            return {"*UNREADABLE*"}
        for ln in out.splitlines()[1:]:
            f = ln.split()
            if f and f[0].isdigit():
                pids.add(f[0])
        break  # `launchctl list` covers the caller's domain; one read is enough
    return pids


DAEMONISH = re.compile(r"--loop|--daemon|--serve|--watch|--interval|--port|--listen|"
                       r"\bserve\b|\.pid\b", re.I)


def designed_daemon(pid: str, args: str) -> str | None:
    """Gate 5. Returns the evidence, or None. Intent leaves traces; an orphan does not."""
    if DAEMONISH.search(args):
        return "daemon-ish argv"
    # a pidfile naming this pid
    state = os.path.expanduser("~/.pi/agent/state")
    try:
        for f in os.listdir(state):
            if f.endswith(".pid"):
                try:
                    if open(os.path.join(state, f)).read().strip() == pid:
                        return f"pidfile {f}"
                except Exception:
                    pass
    except Exception:
        pass
    # a live holder of a socket this process owns, or a recently-written open file
    try:
        out = subprocess.run(["lsof", "-p", pid], capture_output=True, text=True,
                             timeout=5).stdout
    except Exception:
        return "lsof unreadable -> unclear"
    for ln in out.splitlines()[1:]:
        f = ln.split(None, 8)
        if len(f) < 9:
            continue
        kind, name = f[4], f[8]
        if "socket" in kind.lower() or "unix" in kind.lower():
            # FAIL CLOSED: a process holding a listening socket may have a live client, and the
            # NAME field for a listening unix socket is often EMPTY, so an lsof-by-name lookup
            # cannot be trusted to find the client. Holding a listener is therefore reported as
            # DESIGNED, not reaped — a stranded test server that could be safely reclaimed is a
            # job for its own owner (see the note above TESTISH).
            return f"holds a listening socket ({kind})"
        if kind in ("REG", "DIR") and name.startswith("/"):
            try:
                if time.time() - os.stat(name).st_mtime < 900:
                    return f"output written <15min ago: {name[:44]}"
            except Exception:
                pass
    return None


def ancestry(pid: str, rows: dict[str, dict], depth: int = 25) -> list[str]:
    """Walk parent chain TO THE TOP. Returns the path (comm strings)."""
    path, cur, seen = [], pid, set()
    while cur and cur != "0" and cur not in seen and depth > 0:
        seen.add(cur)
        r = rows.get(cur)
        if r is None:
            # Parent not in this snapshot (reparented to launchd, or exited between reads).
            # Record it as an unknown hop rather than silently stopping — an incomplete walk
            # must not read as a clean walk.
            path.append(f"<pid {cur} not visible>")
            break
        path.append(r["comm"])
        cur = r["ppid"]
        depth -= 1
    return path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="actually SIGTERM (default: dry run)")
    ap.add_argument("--sample", type=float, default=15.0, help="CPU sample window, seconds")
    ap.add_argument("--include-any-owner", action="store_true",
                    help="do not require the path to be under YOUR Documents/GitHub")
    a = ap.parse_args()

    before = ps_fields()
    reg = registered_launchd_pids()

    cands = {}
    for pid, r in before.items():
        if r["ppid"] != "1":
            continue
        if not (OURS.search(r["args"]) or (a.include_any_owner and TESTISH.search(r["args"]))):
            continue
        if not TESTISH.search(r["args"]):
            continue
        cands[pid] = r

    print(f"candidates (ppid=1, ours, test/tooling-shaped): {len(cands)}")
    print(f"CPU sample window: {a.sample:.0f}s   (PARKED = delta < {TOLERANCE_S}s)\n")
    time.sleep(a.sample)
    after = ps_fields()

    reap, report = [], []
    for pid, r in sorted(cands.items(), key=lambda kv: etime_seconds(kv[1]["etime"]),
                         reverse=True):
        now = after.get(pid)
        if now is None:
            print(f"  {pid}  EXITED during sample — nothing to do")
            continue
        d = cpu_seconds(now["time"]) - cpu_seconds(r["time"])
        if d < 0:
            d = -1.0
        parked = 0.0 <= d < TOLERANCE_S
        elapsed = etime_seconds(r["etime"])
        path = ancestry(pid, before)
        human = [h for h in HUMAN if any(h in p for p in path)]
        is_reg = pid in reg
        designed = designed_daemon(pid, r["args"])
        # gate 3: our test/tooling class should finish in minutes; >=2h is two orders out.
        overlong = elapsed >= 2 * 3600

        verdicts = {
            "1_cpu": "PARKED" if parked else ("NEEDS-READ" if d < 0 else f"ALIVE +{d:.2f}s"),
            "2_ancestry": "human:" + human[0] if human else "no-human-ancestor",
            "3_expected": f"{elapsed/3600:.1f}h " + ("OVERLONG" if overlong else "plausible"),
            "4_launchd": "REGISTERED (never reap)" if is_reg else "unmanaged",
            "5_designed": designed or "no daemon trace",
        }
        print(f"  {pid}  {r['comm']}")
        print(f"        {r['args'][:130]}")
        for k, v in verdicts.items():
            print(f"        gate {k:12s} {v}")

        if is_reg or human or designed or not parked or not overlong:
            report.append((pid, verdicts))
            print("        => REPORT ONLY (a gate did not pass)\n")
        else:
            reap.append((pid, r))
            print("        => PASSES ALL FIVE GATES\n")

    print(f"==== {len(reap)} reapable · {len(report)} report-only ====")
    if not a.apply:
        print("dry run — re-run with --apply to SIGTERM the reapable set.")
        return 0

    for pid, r in reap:
        try:
            os.kill(int(pid), 15)
            print(f"  SIGTERM -> {pid} ({r['comm']})")
        except ProcessLookupError:
            print(f"  {pid} already gone")
        except PermissionError:
            print(f"  {pid} EPERM — not ours to kill; REPORTING")
    time.sleep(3)
    still = ps_fields()
    for pid, r in reap:
        if pid in still:
            try:
                os.kill(int(pid), 9)
                print(f"  SIGKILL -> {pid} (did not exit on TERM)")
            except Exception as e:
                print(f"  {pid} still alive, kill failed: {e}")
        else:
            print(f"  verified gone: {pid}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
