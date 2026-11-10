#!/usr/bin/env python3
"""probe-one.py — the three-signal read on ONE pid. Reports; never kills.

Signals, per AGENTS.md: cumulative CPU sampled twice (with the tolerance stated),
the parent chain walked to the top (a Terminal/iTerm/login ancestor means HUMAN and
is never touched), and progress judged against the process's own expected bound.
"""
import subprocess
import sys
import time

PID = sys.argv[1]
SAMPLE = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0


def q(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout.strip()


def cpu():
    return q("ps", "-o", "time=", "-p", PID)


def to_s(t):
    try:
        return sum(float(x) * (60 ** i) for i, x in enumerate(reversed(t.split(":"))))
    except Exception:
        return 0.0


print(f"pid {PID}")
print(f"  comm    : {q('ps','-o','comm=','-p',PID) or '(gone)'}")
print(f"  started : {q('ps','-o','lstart=','-p',PID)}")
print(f"  elapsed : {q('ps','-o','etime=','-p',PID)}")
print(f"  cpu     : {q('ps','-o','time=','-p',PID)}")
print(f"  threads : {q('ps','-o','thcount=','-p',PID)}")
cmd = q("ps", "-o", "command=", "-p", PID)
print(f"  argv    : {cmd[:220]}")

print("\n  parent chain (walked to the top):")
cur, chain = PID, []
for _ in range(8):
    pp = q("ps", "-o", "ppid=", "-p", cur)
    if not pp or pp == "0":
        break
    comm = q("ps", "-o", "comm=", "-p", pp)
    chain.append(f"{pp}:{comm}")
    if pp == "1":
        break
    cur = pp
for c in chain:
    print(f"    {c}")
human = any(k in " ".join(chain).lower()
            for k in ("terminal.app", "iterm", "ghostty", "warp"))
# ⛔ NOT `login`. Every cmux pane's chain contains `/usr/bin/login` (cmux spawns
# `login -> zsh`), so keying on it makes the check flag EVERY agent-owned process as
# human and it stops discriminating at all. Measured on pid 79908. The human markers
# are the terminal EMULATORS.
print(f"  HUMAN-OWNED? {'YES - DO NOT TOUCH' if human else 'no (agent/cmux chain)'}")

open_files = q("lsof", "-p", PID).count("\n")
print(f"  open files: {open_files}")

a = cpu()
time.sleep(SAMPLE)
b = cpu()
d = to_s(b) - to_s(a)
print(f"\n  CPU {a} -> {b}   delta {d:.2f}s over {SAMPLE:.0f}s   "
      f"[{'FLAT - parked signature' if d < 0.1 else 'ADVANCING'}]")
