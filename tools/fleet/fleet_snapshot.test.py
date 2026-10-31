#!/usr/bin/env python3
"""tools/fleet/fleet_snapshot.test.py — the population extension's pins.

Run: python3 tools/fleet/fleet_snapshot.test.py
Exit 0 = every pin holds; 1 = a pin failed (named).

WHAT IS PINNED, AND WHY EACH ONE EXISTS
---------------------------------------
1. **The extension is a POPULATION extension, not a second predicate** (#1178).
   A cmux-population Evidence classifies EXACTLY as before — including the store
   gate, which must still fire for the population whose identity source IS the
   store. A mutation that moves the store gate out of its population branch reds
   the first pin.
2. **A dispatch lane with no bound incarnation is an ABSTENTION, never `dead`.**
   This population has no durable fenced incarnation, so `dead` is unreachable
   by design (#1178 C1). A mutation that lets `dead` be reached from an
   unbound-transcript Evidence reds the second pin.
3. **The two REAL shapes from 2026-10-30**, as transcripts:
   * a lane **alive and silent inside one long `bash` call** must read
     `running-quiet/tool-in-flight` (the false-DEAD reading that started this);
   * a lane **alive with no child and no CPU progress** must read `wedged`, and
     its `reason`/`detail` must name the open step (the WHY line).
4. **`UNMEASURED`, never `0`.** Unreadable box data reports a string with a
   reason; a percentage is never manufactured from a failed read; and where
   swap is not configured the answer says so instead of reporting 0 % pressure.
5. **`MAX_LANES` is the shell's derivation, not a new one** (`_NCPU*5/2`
   floored, fallback 10, product bounded).
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import liveness  # noqa: E402
import fleet_snapshot as fs  # noqa: E402

FAILS = []


def ck(name, cond, detail=""):
    if not cond:
        FAILS.append("%s%s" % (name, (": " + detail) if detail else ""))


def write_transcript(path, entries):
    with open(path, "w", encoding="utf-8") as fh:
        for e in entries:
            fh.write(json.dumps(e) + "\n")
    return path


def open_call_transcript(dirpath, sid, age_s):
    """An assistant message carrying a `bash` call with no toolResult after it."""
    path = os.path.join(dirpath, "_%s.jsonl" % sid)
    ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - age_s)) + "Z"
    write_transcript(path, [
        {"type": "session", "id": sid, "cwd": "/tmp"},
        {"type": "message", "timestamp": ts, "message": {
            "role": "assistant", "stopReason": "toolUse",
            "content": [{"type": "toolCall", "name": "bash", "id": "call_00_bisect"}]}},
    ])
    os.utime(path, (time.time() - age_s, time.time() - age_s))
    return path


def resting_transcript(dirpath, sid, age_s):
    path = os.path.join(dirpath, "_%s.jsonl" % sid)
    ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - age_s)) + "Z"
    write_transcript(path, [
        {"type": "session", "id": sid, "cwd": "/tmp"},
        {"type": "message", "timestamp": ts, "message": {
            "role": "assistant", "stopReason": "stop",
            "content": [{"type": "text", "text": "done"}]}},
    ])
    os.utime(path, (time.time() - age_s, time.time() - age_s))
    return path


# ── 1. cmux lanes classify identically (the store gate is population-scoped) ──
v = liveness.evaluate(liveness.Evidence(sid="s", store_ok=False))
ck("1a cmux default population is still gated on the store",
   (v.state, v.reason) == ("unknown", "store-unreadable"), str(v))

holder = liveness.Candidate(pid=4242, observed="holder", kind="argv")
v = liveness.evaluate(liveness.Evidence(
    sid="s", store_ok=None, identity_population=liveness.DISPATCH_POPULATION,
    candidates=[holder], jsonl_grew=False, jsonl_age_ms=liveness.STREAM_STALL_MS + 60_000,
    jsonl_turn=liveness.Turn(False, "turn-ended", "terminal stopReason=stop"), now_ms=0))
ck("1b a dispatch lane is not read as a broken store, and a resting turn is not a stall",
   (v.state, v.reason) == ("running-quiet", "turn-ended"), str(v))

# ── 2. an unbound dispatch lane abstains; it can never read `dead` ────────────
v = liveness.evaluate(liveness.Evidence(
    sid="s", store_ok=None, identity_population=liveness.DISPATCH_POPULATION,
    candidates=[], jsonl_grew=False, jsonl_age_ms=5_000, now_ms=0,
    dispatch_detail="unbound; transcript x.jsonl, last write 0m05s ago"))
ck("2a unbound dispatch lane abstains with a named reason",
   (v.state, v.reason) == ("unknown", "no-bound-incarnation"), str(v))
ck("2b the abstention carries the WHY line", "unbound" in (v.detail or ""), str(v))
ck("2c `dead` is unreachable for this population",
   all(liveness.evaluate(liveness.Evidence(
       sid="s", store_ok=None, identity_population=liveness.DISPATCH_POPULATION,
       candidates=[], jsonl_grew=g, jsonl_age_ms=a, now_ms=0)).state != "dead"
       for g in (False, True, None) for a in (0, liveness.IDLE_MS * 2, None)))

# ── 3. the two REAL shapes from 2026-10-30 ──────────────────────────────────
tmp = tempfile.mkdtemp(prefix="fleet-snap-test-")

# 3a: alive, silent 83 minutes inside ONE bash call -> WORKING, not WEDGED.
# The age is well past STREAM_STALL_MS (20 min), so silence alone would have
# read "no writing lately"; the in-flight tool veto is what keeps it working.
p = open_call_transcript(tmp, "01a19013-02f8-764c-82f5-76cdb0a9da48", 83 * 60)
ev = liveness.gather_dispatch("01a19013-02f8-764c-82f5-76cdb0a9da48", pid=None,
                              transcript=p, sessions_dir=tmp)
ev.candidates = [holder]
v = liveness.evaluate(ev)
ck("3a a lane silent 83m inside one bash call reads running-quiet/tool-in-flight",
   (v.state, v.reason) == ("running-quiet", "tool-in-flight"), str(v))
ck("3a' and its evidence names WHICH call holds it",
   "bash(call_00_bisect)" in (v.detail or ""), str(v))

# 3b: alive, no child, no CPU progress, transcript frozen -> WEDGED with a WHY.
p = open_call_transcript(tmp, "01a19014-0000-7000-8000-000000000001", 4 * 3600)
ev = liveness.gather_dispatch("01a19014-0000-7000-8000-000000000001", pid=None,
                              transcript=p, sessions_dir=tmp)
ev.candidates = [holder]
v = liveness.evaluate(ev)
ck("3b a lane with no child and no CPU progress past every backstop reads wedged",
   v.state == "wedged", str(v))
ck("3b' the wedged row names the open step (the WHY line)",
   "bash(call_00_bisect)" in (v.detail or "") and v.reason.startswith("turn-open:"), str(v))

# 3c: the control — a lane that finished its turn rests, it is not wedged.
p = resting_transcript(tmp, "01a19015-0000-7000-8000-000000000002", 4 * 3600)
ev = liveness.gather_dispatch("01a19015-0000-7000-8000-000000000002", pid=None,
                              transcript=p, sessions_dir=tmp)
ev.candidates = [holder]
v = liveness.evaluate(ev)
ck("3c a turn-ended lane rests instead of reading wedged (the #1254 direction)",
   (v.state, v.reason) == ("running-quiet", "turn-ended"), str(v))

# ── 4. UNMEASURED, never 0 ─────────────────────────────────────────────────
empty = tempfile.mkdtemp(prefix="fleet-snap-empty-")
liveness.load_store.__defaults__  # (no-op: keeps the import honest)
snap = fs.snapshot(box="test-box", sessions_dir=empty,
                   store_path=os.path.join(empty, "absent.json"),
                   task_sessions=empty, capacity_path=os.path.join(empty, "absent.sh"))
cmux_decl = snap["lanes"][liveness.CMUX_POPULATION]["declaration"]
ck("4a an unreadable hook store reports UNMEASURED(<why>), not 0 lanes",
   cmux_decl.get("state", "").startswith(fs.U), json.dumps(cmux_decl)[:160])
ck("4b a missing capacity.sh reports UNMEASURED(<why>), not zeros",
   str(snap["box"]["metrics"].get("state", "")).startswith(fs.U), json.dumps(snap["box"])[:160])
pct, why = fs.swap_used_pct(meminfo=os.path.join(empty, "no-meminfo"), sysctl=os.path.join(empty, "no-sysctl"))
ck("4c an unreadable swap probe is UNMEASURED, not 0%", pct is None and why.startswith(fs.U), str((pct, why)))
pct, why = fs.swap_used_pct(meminfo=os.path.join(empty, "mi"),
                            sysctl=os.path.join(empty, "no-sysctl"))
ck("4d an empty/unreadable pair of probes is an abstention", pct is None and why.startswith(fs.U),
   str((pct, why)))
mi = os.path.join(empty, "mi-swap")
with open(mi, "w") as fh:
    fh.write("SwapTotal:             0 kB\nSwapFree:              0 kB\n")
pct, why = fs.swap_used_pct(meminfo=mi)
ck("4e a box with NO swap says so instead of reporting 0% pressure",
   pct is None and "no swap configured" in why, str((pct, why)))
mi = os.path.join(empty, "mi-ok")
with open(mi, "w") as fh:
    fh.write("SwapTotal:       8388608 kB\nSwapFree:        6291456 kB\n")
pct, why = fs.swap_used_pct(meminfo=mi)
ck("4f a readable swap line yields the percentage", pct == 25, str((pct, why)))

# ── 5. MAX_LANES is the shell's derivation ────────────────────────────────
ck("5a 10 cores -> 25 lanes (the shell's 2.5x, floored)", fs.max_lanes("10")[0] == 25, str(fs.max_lanes("10")))
ck("5b 4 cores -> 10 lanes", fs.max_lanes("4")[0] == 10, str(fs.max_lanes("4")))
ck("5c an absurd probe falls back to 10, not a fan-out", fs.max_lanes("999999999")[0] == 10, str(fs.max_lanes("999999999")))
ck("5d an unreadable probe falls back to 10", fs.max_lanes("")[0] == 10, str(fs.max_lanes("")))

# ── 6. the binding is read from the process environment, and only for pi ────
proc = tempfile.mkdtemp(prefix="fleet-snap-proc-")
os.makedirs(os.path.join(proc, "4242"))
with open(os.path.join(proc, "4242", "comm"), "w") as fh:
    fh.write("pi\n")
with open(os.path.join(proc, "4242", "environ"), "wb") as fh:
    fh.write(b"HOME=/root\0PI_SESSION_ID=01a19013-02f8-764c-82f5-76cdb0a9da48\0")
os.makedirs(os.path.join(proc, "4343"))
with open(os.path.join(proc, "4343", "comm"), "w") as fh:
    fh.write("postgres\n")
with open(os.path.join(proc, "4343", "environ"), "wb") as fh:
    fh.write(b"PI_SESSION_ID=not-a-pi-process\0")
bindings, why = fs.proc_bindings(root=proc)
ck("6a a pi process binds its session from /proc/<pid>/environ",
   bindings.get("01a19013-02f8-764c-82f5-76cdb0a9da48") == 4242, str(bindings))
ck("6b a non-pi process is never treated as a lane holder",
   "not-a-pi-process" not in bindings, str(bindings))
bindings, why = fs.proc_bindings(root=os.path.join(empty, "no-proc"))
ck("6c no /proc is UNMEASURED(<why>) — never an empty 'nothing is running'",
   bindings == {} and why.startswith(fs.U), why)

if FAILS:
    print("FAIL (%d):" % len(FAILS))
    for f in FAILS:
        print("  - " + f)
    sys.exit(1)
print("PASS: %d pins hold (population extension, 2 real shapes, UNMEASURED, MAX_LANES, binding)"
      % 18)
