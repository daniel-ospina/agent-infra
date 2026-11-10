#!/usr/bin/env python3
"""child-check.py — the three-signal read on `task` children. REPORTS; never kills.

AGENTS.md: parked CPU is NECESSARY and ancestry is the SUFFICIENT guard, so CPU
alone is never the verdict. This gathers cumulative CPU sampled twice, recent disk
writes in each child's own cwd, and the parent chain — and leaves the decision to a
human. It never signals anything.

Usage: python3 child-check.py [sample_seconds]
"""
import os
import subprocess
import sys
import time

SAMPLE = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0


def pi_cwds():
    """{pid: cwd} for every live pi process — TWO calls total, not one per pid.

    Two earlier versions of this were wrong, and both are worth remembering:
      * looping `lsof -p <pid>` over every process on the box (~700) took minutes
        and timed out;
      * `lsof -a -d cwd -c pi` returns NOTHING here even though 53 processes have
        `comm == pi`, so the `-c` filter silently produced an empty census — the
        same "empty reads as clean" shape that caused the question-gate bug.
    `ps` names the pids; ONE `lsof -p a,b,c…` gets every cwd.
    """
    ps = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True,
                        text=True).stdout
    pids = [ln.split()[0] for ln in ps.splitlines()
            if len(ln.split()) == 2 and ln.split()[1] == "pi"]
    if not pids:
        return {}
    out = subprocess.run(["lsof", "-a", "-d", "cwd", "-p", ",".join(pids),
                          "-Fpn"], capture_output=True, text=True).stdout
    res, pid = {}, None
    for line in out.splitlines():
        if line.startswith("p"):
            pid = line[1:]
        elif line.startswith("n") and pid:
            res[pid] = line[1:]
    return res


def cpu(pid):
    try:
        return subprocess.run(["ps", "-o", "time=", "-p", pid],
                              capture_output=True, text=True).stdout.strip()
    except Exception:
        return "?"


def ppid(pid):
    try:
        return subprocess.run(["ps", "-o", "ppid=", "-p", pid],
                              capture_output=True, text=True).stdout.strip()
    except Exception:
        return "?"


def ancestry(pid, depth=6):
    chain, cur = [], pid
    for _ in range(depth):
        p = ppid(cur)
        if not p or p == "0":
            break
        try:
            comm = subprocess.run(["ps", "-o", "comm=", "-p", p],
                                  capture_output=True, text=True).stdout.strip()
        except Exception:
            comm = "?"
        chain.append(f"{p}:{os.path.basename(comm)}")
        if p == "1":
            break
        cur = p
    return " <- ".join(chain) or "(ppid=1)"


t1 = pi_cwds()
before = {p: cpu(p) for p in t1}
print(f"pi processes with a cwd: {len(t1)}  (sampling {SAMPLE:.0f}s)\n")
time.sleep(SAMPLE)
after = {p: cpu(p) for p in pi_cwds()}

# group by cwd so one worktree shows as one row
rows = {}
for p, cwd in t1.items():
    rows.setdefault(cwd, []).append(p)

for cwd, pids in sorted(rows.items()):
    for p in pids:
        b, a = before.get(p, "?"), after.get(p, "?")
        flat = "FLAT" if (b == a and b != "?") else "MOVING"
        try:
            n = int(subprocess.run(
                ["find", cwd, "-type", "f", "-mmin", "-5"],
                capture_output=True, text=True, timeout=60).stdout.count("\n"))
        except Exception:
            n = -1
        print(f"{cwd}")
        print(f"    pid={p}  cpu {b} -> {a}   [{flat}]   disk writes/5m={n}")
        print(f"    ancestry: {ancestry(p)}")
