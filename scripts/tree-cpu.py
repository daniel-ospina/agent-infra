#!/usr/bin/env python3
"""tree-cpu.py — is a `pi` process's OWN cpu flat while its DESCENDANTS advance?

The question this answers: if we auto-kill on "0 CPU delta", do we kill children that
are legitimately blocked on a long tool call? A `pi` agent running `bash("pytest ...")`
is in waitpid() at ~0% CPU while pytest does the work. Measuring only the `pi` process
would call that "parked".

So: for every live `pi`, sample (own cpu, sum of descendants) twice and classify.

  OWN-FLAT / TREE-WORKING  -> the dangerous case: auto-kill would be WRONG
  OWN-FLAT / TREE-FLAT     -> a real park candidate
  OWN-WORKING              -> working, no question

Read-only. Kills nothing.
"""
import os
import re
import subprocess
import time
from collections import defaultdict

PS = "/bin/ps"


def ps_rows():
    """pid -> (ppid, comm, cputime_seconds)"""
    out = subprocess.run([PS, "-axo", "pid=,ppid=,comm=,time="],
                         capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(\d+)\s+(\S+)\s+([\d:.]+)\s*$", line)
        if not m:
            continue
        pid, ppid, comm, t = int(m.group(1)), int(m.group(2)), m.group(3), m.group(4)
        parts = [float(x) for x in t.split(":")] if ":" in t else [float(t)]
        secs = 0.0
        for p in parts:
            secs = secs * 60 + p
        rows[pid] = (ppid, comm, secs)
    return rows


def descendants(root, rows):
    kids = defaultdict(list)
    for pid, (ppid, _c, _s) in rows.items():
        kids[ppid].append(pid)
    seen, stack = set(), list(kids.get(root, []))
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        stack.extend(kids.get(p, []))
    return seen


def snapshot():
    rows = ps_rows()
    pi = {p: v for p, v in rows.items() if v[1] == "pi"}
    res = {}
    for p in pi:
        desc = descendants(p, rows)
        res[p] = {
            "own": rows[p][2],
            "tree": rows[p][2] + sum(rows[d][2] for d in desc if d in rows),
            "ndesc": len(desc),
            "heaviest": max((rows[d][2], d, rows[d][1]) for d in desc) if desc else None,
            "ppid": rows[p][0],
        }
    return res


def main():
    gap = float(os.environ.get("GAP", "20"))
    a = snapshot()
    print(f"sampling {len(a)} pi processes for {gap:.0f}s ...")
    time.sleep(gap)
    b = snapshot()

    both = [p for p in a if p in b]
    print(f"still alive after the gap: {len(both)} of {len(a)}")
    print()

    dangerous, candidates, working = [], [], []
    for p in both:
        down = round(b[p]["own"] - a[p]["own"], 2)
        dtree = round(b[p]["tree"] - a[p]["tree"], 2)
        row = (p, a[p]["own"], down, dtree, b[p]["ndesc"], b[p]["heaviest"])
        if down <= 0.05 and dtree <= 0.05:
            candidates.append(row)
        elif down <= 0.05 < dtree:
            dangerous.append(row)
        else:
            working.append(row)

    hdr = f"{'pid':>7} {'own_cpu':>9} {'d_own':>7} {'d_tree':>8} {'#desc':>6}  heaviest descendant"
    def show(title, rows, note):
        print(f"=== {title}  ({len(rows)}) — {note}")
        if rows:
            print("  " + hdr)
            for p, own, down, dtree, nd, heav in sorted(rows, key=lambda r: -r[3])[:14]:
                h = f"{heav[2]} pid={heav[1]} cpu={heav[0]:.1f}s" if heav else "-"
                print(f"  {p:>7} {own:>9.2f} {down:>7.2f} {dtree:>8.2f} {nd:>6}  {h}")
        print()

    show("OWN-FLAT / TREE-WORKING", dangerous,
         "AUTO-KILL WOULD BE WRONG — this is a blocked-on-tool-call child")
    show("OWN-FLAT / TREE-FLAT", candidates, "real park candidates")
    show("OWN-WORKING", working, "no question")

    print("VERDICT")
    if dangerous:
        tot = sum(r[3] for r in dangerous)
        print(f"  {len(dangerous)} of {len(both)} pi processes have a flat own-CPU with a")
        print(f"  WORKING descendant subtree ({tot:.1f} cpu-s/interval hidden).")
        print("  => 'own CPU == 0' is NOT a safe park marker. It is a safe marker only")
        print("     for the WHOLE TREE.")
    else:
        print("  none observed this sample — inconclusive, re-run before concluding")


if __name__ == "__main__":
    main()
