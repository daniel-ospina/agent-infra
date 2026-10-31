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
2. **A dispatch lane can never read `dead`, BOUND or UNBOUND.**
   This population has no durable fenced incarnation: the pid it reports is
   BORROWED from a separate process's environment, and the probe answers
   "this pid is listed", never "this pid IS this transcript". So a witness
   reading is the same uncertainty as an unbound row — and a lane whose bound
   process exits between the pass's `/proc` read and its own probe (ordinary
   fleet life) must not render the false DEAD this population exists to
   remove. Pins `2a`-`2c` hold the unbound shape, `2d`-`2g` the bound-then-
   absent shape through the REAL acquisition path, and `2e` proves the arm is
   population-scoped rather than a blanket suppression of death evidence.
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
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import liveness  # noqa: E402
import fleet_snapshot as fs  # noqa: E402

LIVENESS_PATH = os.path.join(HERE, "liveness.py")
SNAPSHOT_PATH = os.path.join(HERE, "fleet_snapshot.py")
SELF_PATH = os.path.abspath(__file__)

FAILS = []
PINS = [0]


def ck(name, cond, detail=""):
    PINS[0] += 1
    if not cond:
        FAILS.append("%s%s" % (name, (": " + detail) if detail else ""))


# ── mutation evidence: a green pin is only a pin if it can go RED ──────────
# Each entry reintroduces ONE defect into a TEMP copy of the module and re-runs
# this whole suite against it in a subprocess. The paired pin is named, and a
# mutation the suite does not catch is reported as a suite failure — the same
# discipline every other fleet suite here follows (`liveness.test.py
# --mutations`, `lane_liveness.test.py --red-control`).
MUTATIONS = [
    ("drop-borrowed-incarnation-arm", "classifier",
     "if ev.identity_population == DISPATCH_POPULATION and is_dead_evidence(cands):",
     "if False and is_dead_evidence(cands):",
     "2d",
     "a dispatch lane whose bound pid reads `absent` renders `dead` again (the false DEAD #1178 removes)"),
    ("unscope-the-store-gate", "classifier",
     "if ev.identity_population == CMUX_POPULATION and not ev.store_ok:",
     "if not ev.store_ok:",
     "1b",
     "every dispatch lane on a store-less box reads `store-unreadable` instead of a verdict"),
    ("no-swap-reports-zero", "snapshot",
     '        if total == 0:\n            return None, unmeasured("no swap configured")',
     '        if total == 0:\n            return 0, ""',
     "4e",
     "a box with no swap reports 0% pressure, which reads as the opposite claim"),
    ("unbound-max-lanes", "snapshot",
     "if derived < 1 or derived > 100:",
     "if False:",
     "5c",
     "an absurd core count fans the box out to a ten-digit lane ceiling"),
    ("any-process-is-a-lane", "snapshot",
     'if comm not in ("pi", "node", "Pi"):',
     "if False:",
     "6b",
     "every process with a PI_SESSION_ID in its env is bound as a lane holder"),
]


def run_mutations():
    print("── MUTATIONS — each reintroduced defect must make its paired pin RED ──\n")
    caught = missed = 0
    for name, target, old, new, pin, why in MUTATIONS:
        tmp = tempfile.mkdtemp(prefix="fleet-snap-mut-")
        try:
            for src in (LIVENESS_PATH, SNAPSHOT_PATH, SELF_PATH):
                shutil.copy2(src, tmp)
            path = os.path.join(tmp, "liveness.py" if target == "classifier" else "fleet_snapshot.py")
            with open(path, "r", encoding="utf-8") as fh:
                source = fh.read()
            if source.count(old) != 1:
                raise SystemExit("mutation anchor not unique in %s (%d hits):\n%s"
                                 % (path, source.count(old), old))
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(source.replace(old, new, 1))
            proc = subprocess.run([sys.executable, os.path.join(tmp, os.path.basename(SELF_PATH))],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=tmp)
            out = proc.stdout.decode("utf-8", "replace")
            red = proc.returncode != 0 and ("  - " + pin) in out
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        print("── %s → %s" % (name, why))
        print("   suite rc=%d, pinned %s went red=%s" % (proc.returncode, pin, red))
        if red:
            caught += 1
            print("   ✅ RED — the suite caught the reintroduced defect\n")
        else:
            missed += 1
            print("   ❌ NOT RED — the suite did NOT catch its own defect\n")
    print("MUTATIONS=%d caught=%d missed=%d" % (len(MUTATIONS), caught, missed))
    return 0 if missed == 0 else 1


if "--mutations" in sys.argv[1:]:
    sys.exit(run_mutations())


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

# ── 2d/2e. the BOUND-then-absent shape: borrowed incarnation, never a fence ──
# A dispatch lane's pid comes out of another process's environment, so `absent`
# on it says only "the process this row was bound to is no longer listed". These
# pins FAIL on the pre-fix ladder, which returned `dead/incarnations-absent`.
for observed in ("absent", "zombie"):
    v = liveness.evaluate(liveness.Evidence(
        sid="s", store_ok=None, identity_population=liveness.DISPATCH_POPULATION,
        candidates=[liveness.Candidate(pid=4242, observed=observed, kind="argv")],
        jsonl_grew=False, jsonl_age_ms=liveness.IDLE_MS // 2, now_ms=0,
        dispatch_detail="bound pid=4242; transcript x.jsonl, last write 83m00s ago"))
    ck("2d a bound-then-%s dispatch lane abstains instead of reading dead" % observed,
       (v.state, v.reason) == ("unknown", "no-bound-incarnation"), str(v))
    ck("2d' the abstention keeps the probe reading as evidence (%s)" % observed,
       ("4242:%s" % observed) in (v.witnesses or ()) and "4242" in (v.detail or ""), str(v))

# 2e: the arm is POPULATION-SCOPED. The identical candidate set still reads
# `dead` in the cmux population — whose incarnation IS fenced — so 2d cannot be
# satisfied by a blanket suppression of death evidence.
v = liveness.evaluate(liveness.Evidence(
    sid="s", store_ok=True,
    candidates=[liveness.Candidate(pid=4242, observed="absent", kind="argv")],
    jsonl_grew=False, jsonl_age_ms=liveness.IDLE_MS // 2, now_ms=0))
ck("2e the same absent binding still reads dead in the cmux population (arm is population-scoped)",
   (v.state, v.reason) == ("dead", "incarnations-absent"), str(v))

# 2f/2g/2h: the REAL acquisition path. `gather_dispatch`'s pid branch had no pin
# at all — 3a/3b/3c pass pid=None and then overwrite `ev.candidates` by hand. A
# 3-line shim stands in for the identity CLI, so the binding, the probe mapping
# and the ladder are exercised end to end with no live process and no ps read.
shim_dir = tempfile.mkdtemp(prefix="fleet-snap-lib-")


def shim(name, body):
    path = os.path.join(shim_dir, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\n%s\n" % body)
    return path


absent_lib = shim("absent.sh", 'echo "absent pid=$2"; exit 1')
holder_lib = shim("holder.sh", 'echo "holder pid=$2"; exit 0')
bind_dir = tempfile.mkdtemp(prefix="fleet-snap-bind-")
bind_sid = "01a19016-0000-7000-8000-000000000003"
p = resting_transcript(bind_dir, bind_sid, 4 * 3600)
ev = liveness.gather_dispatch(bind_sid, pid=4242, transcript=p, sessions_dir=bind_dir,
                              lib=absent_lib)
ck("2f gather_dispatch turns the bound pid into a probed candidate (real acquisition path)",
   [(c.pid, c.observed) for c in ev.candidates] == [(4242, "absent")], str(ev.candidates))
v = liveness.evaluate(ev)
ck("2g a bound pid the probe reports ABSENT reads an abstention, never dead",
   (v.state, v.reason) == ("unknown", "no-bound-incarnation"), str(v))
ev = liveness.gather_dispatch(bind_sid, pid=4242, transcript=p, sessions_dir=bind_dir,
                              lib=holder_lib)
v = liveness.evaluate(ev)
ck("2h the SAME row with a live holder is still classified (the arm does not blind a live lane)",
   (v.state, v.reason) == ("running-quiet", "turn-ended"), str(v))

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
      % PINS[0])
