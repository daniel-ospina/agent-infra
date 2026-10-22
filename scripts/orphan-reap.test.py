#!/usr/bin/env python3
"""orphan-reap.test.py — the gate suite for the `pi` pool (scripts/orphan-reap.py).

SIX tests, each with its own fixture, and THREE MUTATIONS that must go RED when a gate is
dropped. No live process is touched and nothing here can signal a pid: `ps`, the session index,
`stat`, the clock and the cmux hook store are all injected, and the only thing read back is the
census's own `--json` output (so the CLI path is exercised, not a copy of it).
⚠️ ONE READER IS REAL, ON PURPOSE: `canon_verdict` calls the canon's `gather`, which forks the
fleet's identity probe (`scripts/lib/pid-identity.sh`) for the store record it is given. That is
the RULE under test, not a fixture, so a provider machine without a working probe CLI fails these
tests RED (`canon:unknown:ps-unreadable`) instead of passing on a stub — fail-closed and loud,
which is why the CI step depends on it.

    python3 scripts/orphan-reap.test.py              # the suite
    python3 scripts/orphan-reap.test.py --mutations   # every mutation must FAIL its test

(a) sleeping child, no terminal ancestor, zero CPU delta          => PARKED-REAPABLE
(b) the same child under a fake login-shell ancestor              => KEEP-HUMAN
(c) zero CPU delta but the transcript GREW                        => LIVE   (progress beats CPU)
(d) a pid that vanished between the two reads                     => UNVERIFIABLE, no crash
(e) CPU advanced 120 s over the window                            => LIVE
(f) canon RECORD VETO: the lane's own store record is fresh       => UNVERIFIABLE, never `idle`
    (this is the finding the first draft failed: asserting `store_ok=True` made the canon's
    #947 record veto structurally unreachable, so a lane whose record says it just consumed
    input was reapable as `idle`)
plus: the four states are each reachable, and the name-stamp parser is UTC (not local).
"""
from __future__ import annotations

import calendar
import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SPEC = importlib.util.spec_from_file_location("orphan_reap", os.path.join(HERE, "orphan-reap.py"))
mod = importlib.util.module_from_spec(SPEC)
sys.modules["orphan_reap"] = mod          # dataclasses resolve their module from sys.modules
SPEC.loader.exec_module(mod)

# the canon verdict module, from the repo (a farmed install resolves its own copy)
os.environ.setdefault("ORPHAN_REAP_FLEET_DIR", os.path.join(ROOT, "tools", "fleet"))

SID = "01a163dc-5181-7347-b22f-977d2081b6e3"


def _stamp_name(epoch: float) -> str:
    """A session filename's UTC stamp, exactly as pi writes it: `…T13-45-15-602Z`."""
    return time.strftime("%Y-%m-%dT%H-%M-%S", time.gmtime(epoch)) + "-%03dZ" % int(
        (epoch % 1) * 1000)


def _iso(t: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(t))


def _row(pid, ppid, comm="pi", args="pi", time_="00:01:00", etime="05:00:00", stat="Ss"):
    return {"pid": str(pid), "ppid": str(ppid), "stat": stat, "time": time_, "etime": etime,
            "comm": comm, "args": args}


def write_transcript(tmp: str, last_epoch: float, n: int = 8, gap: float = 2.0) -> str:
    """A terminal (turn-ENDED) transcript named `<UTC stamp>_<sid>.jsonl`, mtime = last_epoch.

    The mtime is gate 3's age; the gaps between the stamps are gate 3's OWN expected interval;
    the name-stamp is what the binding fence matches against `now - etime`.
    """
    start = last_epoch - (n - 1) * gap - 2
    path = os.path.join(tmp, "%s_%s.jsonl" % (_stamp_name(start), SID))
    lines = [{"type": "session", "timestamp": _iso(start), "cwd": tmp, "id": SID}]
    for i in range(n - 1):
        lines.append({"type": "message", "timestamp": _iso(last_epoch - (n - 1 - i) * gap),
                      "message": {"role": "user", "content": [{"type": "text", "text": "go"}]}})
    lines.append({"type": "message", "timestamp": _iso(last_epoch),
                  "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}],
                              "stopReason": "stop"}})
    with open(path, "w", encoding="utf-8") as fh:
        for e in lines:
            fh.write(json.dumps(e) + "\n")
    os.utime(path, (last_epoch, last_epoch))
    return path


def write_store(tmp: str, *, pid: int, start_s: float, cwd: str, fresh: bool) -> str:
    """A cmux hook store carrying ONE record: fresh/awake (veto) or idle-and-old (no veto)."""
    now = time.time()
    rec = {
        "pid": pid,
        "pidStartSeconds": int(start_s),
        "cwd": cwd,
        "agentLifecycle": "busy" if fresh else "idle",
        "runtimeStatus": "running" if fresh else "idle",
        "updatedAt": (now - 60) if fresh else (now - 40 * 3600),
    }
    path = os.path.join(tmp, "pi-hook-sessions.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({SID: rec}, fh)
    return path


class Clock:
    """The injected clock. `sleep` ADVANCES it, so a reference taken after the window drifts.

    This is what catches the fence bug: a binding that computes `now - etime` AFTER the CPU
    window is off by the whole window, and every start-stamp leaves the fence.
    """

    def __init__(self, t):
        self.t = float(t)

    def time(self):
        return self.t

    def sleep(self, s):
        self.t += float(s)

    def __getattr__(self, name):
        import time as _t
        return getattr(_t, name)


class Box:
    """An injected process table + session index + store + clock for one census."""

    def __init__(self, rows_before, rows_after, transcript, start_ts, sizes=None, store=None):
        self.rows = [rows_before, rows_after]
        self.ps_calls = 0
        self.stat_calls = 0
        self.transcript = transcript
        self.start_ts = start_ts
        self.sizes = sizes        # optional [size_before, size_after] to fake growth
        self.store = store
        self.clock = Clock(time.time())

    # ── the injected readers ────────────────────────────────────────────
    def ps(self):
        snap = self.rows[min(self.ps_calls, len(self.rows) - 1)]
        self.ps_calls += 1
        return {pid: dict(r) for pid, r in snap.items()}

    def stat(self, path):
        self.stat_calls += 1
        try:
            mtime = os.stat(path).st_mtime
        except OSError:
            return None
        if self.sizes is None:
            return (mtime, 1) if path != self.transcript else (mtime, 4096)
        return (mtime, self.sizes[0 if self.stat_calls <= 1 else -1])

    def census(self, gates=None, sample=20.0) -> dict:
        names = ("ps_pi_fields", "session_index", "_cwd_of_pid", "_stat", "time",
                 "SESSIONS_DIR", "STORE_PATH")
        saved = {n: getattr(mod, n) for n in names}
        buf = io.StringIO()
        mod.ps_pi_fields = self.ps
        mod.session_index = lambda sessions_dir=None: [(self.transcript, self.start_ts)]
        mod._cwd_of_pid = lambda pid: None
        mod._stat = self.stat
        mod.time = self.clock          # sleep advances it: a post-window reference must drift
        mod.SESSIONS_DIR = os.path.dirname(self.transcript)
        mod.STORE_PATH = self.store
        try:
            with contextlib.redirect_stdout(buf):
                rc = mod.pi_census(sample, apply=False, as_json=True, gates=gates,
                                   store_path=self.store)
        finally:
            for n, v in saved.items():
                setattr(mod, n, v)
        assert rc == 0, f"census exited {rc}"
        out = json.loads(buf.getvalue())
        assert out["sample_s"] == sample, f"census ignored the sample window: {out['sample_s']}"
        return out


def row_of(out: dict, pid="100") -> dict:
    for row in out["rows"]:
        if row["pid"] == str(pid):
            return row
    raise AssertionError(f"pid {pid} missing from the census: {out['rows']}")


# ── the fixtures ────────────────────────────────────────────────────────────────────────────
def case_a(tmp) -> Box:
    """A sleeping `pi` at ppid 1, zero CPU delta, a 30 h-frozen transcript."""
    now = time.time()
    t = write_transcript(tmp, now - 30 * 3600)
    before = {"100": _row(100, 1)}
    return Box(before, before, t, now - 5 * 3600,
               store=write_store(tmp, pid=100, start_s=now - 5 * 3600, cwd=tmp, fresh=False))


def case_b(tmp) -> Box:
    """The SAME child, but the walk reaches a login shell: a human owns it."""
    now = time.time()
    t = write_transcript(tmp, now - 30 * 3600)
    before = {"100": _row(100, 200), "200": _row(200, 1, comm="/usr/bin/login", args="-pflogin")}
    return Box(before, before, t, now - 5 * 3600,
               store=write_store(tmp, pid=100, start_s=now - 5 * 3600, cwd=tmp, fresh=False))


def case_c(tmp) -> Box:
    """Zero CPU delta, but the transcript GREW inside the window: LIVE."""
    now = time.time()
    t = write_transcript(tmp, now - 60)
    before = {"100": _row(100, 1)}
    return Box(before, before, t, now - 5 * 3600,
               sizes=[1024, 8192],          # before-read, after-read: it grew
               store=write_store(tmp, pid=100, start_s=now - 5 * 3600, cwd=tmp, fresh=False))


def case_d(tmp) -> Box:
    """A pid present in the first read and gone in the second: an incomplete read."""
    now = time.time()
    t = write_transcript(tmp, now - 30 * 3600)
    before = {"100": _row(100, 1)}
    return Box(before, {}, t, now - 5 * 3600,
               store=write_store(tmp, pid=100, start_s=now - 5 * 3600, cwd=tmp, fresh=False))


def case_e(tmp) -> Box:
    """CPU advanced 120 s over the window (a spin): LIVE, whatever the transcript says."""
    now = time.time()
    t = write_transcript(tmp, now - 30 * 3600)
    before = {"100": _row(100, 1, time_="00:01:00")}
    after = {"100": _row(100, 1, time_="00:03:00")}
    return Box(before, after, t, now - 5 * 3600,
               store=write_store(tmp, pid=100, start_s=now - 5 * 3600, cwd=tmp, fresh=False))


def case_f(tmp) -> Box:
    """A 30 h-frozen transcript whose OWN store record says it consumed input a minute ago."""
    now = time.time()
    t = write_transcript(tmp, now - 30 * 3600)
    before = {"100": _row(100, 1)}
    return Box(before, before, t, now - 5 * 3600,
               store=write_store(tmp, pid=100, start_s=now - 5 * 3600, cwd=tmp, fresh=True))


TESTS = [
    ("(a) sleeping child, no terminal ancestor, zero delta",
     case_a, "PARKED-REAPABLE", "parked-and-retired", None),
    ("(b) same child under a fake login-shell ancestor",
     case_b, "KEEP-HUMAN", "human-ancestor:/usr/bin/login", {"2": False}),
    ("(c) zero delta but a growing transcript (progress beats CPU)",
     case_c, "LIVE", "transcript-growing", {"3": False}),
    ("(d) a pid that vanished mid-read",
     case_d, "UNVERIFIABLE", "vanished-mid-read", None),
    ("(e) CPU advanced 120 s over the window",
     case_e, "LIVE", "cpu-advancing", {"1": False}),
    ("(f) canonical record veto: the lane's own record is fresh",
     case_f, "UNVERIFIABLE", "canon:running-quiet:record-non-idle-fresh", None),
]


def run_one(fn, gates=None):
    tmp = tempfile.mkdtemp(prefix="orphan-reap-test-")
    try:
        return fn(tmp).census(gates)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def suite(mutate: dict | None = None) -> int:
    fails = 0
    for name, fn, expect, expect_reason, mutation in TESTS:
        gates = mutate if (mutate and mutation) else None
        try:
            out = run_one(fn, gates)
        except Exception as exc:                       # a crash IS a failure, named
            print(f"FAIL {name}: {type(exc).__name__}: {exc}")
            fails += 1
            continue
        row = row_of(out)
        ok = row["state"] == expect and (mutate or row["reason"] == expect_reason)
        if list(out["counts"]) != list(mod.POOL_STATES):
            ok = False
        print(f"{'PASS' if ok else 'FAIL'} {name}: {row['state']} ({row['reason']}), "
              f"expected {expect}" + ("" if mutate else f" ({expect_reason})"))
        if not ok:
            fails += 1
            for r in row["readings"]:
                print(f"       reading: {r}")
            print(f"       counts: {out['counts']}")
    return fails


def four_states_reachable() -> int:
    """Every one of the four states must be producible — no state may be a decorative name."""
    seen = set()
    for _name, fn, _expect, _r, _m in TESTS:
        try:
            seen.add(row_of(run_one(fn))["state"])
        except Exception:
            pass
    missing = [s for s in mod.POOL_STATES if s not in seen]
    print(f"{'PASS' if not missing else 'FAIL'} four states reachable across the fixtures: "
          f"{sorted(seen)}" + (f" · MISSING {missing}" if missing else ""))
    return 0 if not missing else 1


def utc_stamp() -> int:
    """The name-stamp is UTC. Under a non-UTC TZ a local-time parse shifts it by the offset."""
    truth = calendar.timegm((2026, 10, 22, 13, 45, 15)) + 0.602
    name = "2026-10-22T13-45-15-602Z_" + SID + ".jsonl"
    saved_tz = os.environ.get("TZ")
    worst = 0.0
    for tz in ("UTC", "Europe/Madrid", "America/Los_Angeles", "Asia/Tokyo"):
        os.environ["TZ"] = tz
        time.tzset()
        worst = max(worst, abs(mod._file_stamp_s(name) - truth))
    if saved_tz is None:
        os.environ.pop("TZ", None)
    else:
        os.environ["TZ"] = saved_tz
    time.tzset()
    ok = worst < 0.01
    print(f"{'PASS' if ok else 'FAIL'} name-stamp is UTC across 4 timezones "
          f"(worst offset {worst:.2f}s)")
    return 0 if ok else 1


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    print("── suite ──")
    fails = suite(None) + four_states_reachable() + utc_stamp()
    if fails:
        print(f"\n{fails} test(s) FAILED")
        return 1
    print("\nall 6 gate tests PASS")

    if "--mutations" not in argv:
        print("(run with --mutations to prove each gate is load-bearing)")
        return 0

    print("\n── mutations: each dropped gate must make its test FAIL ──")
    mut_fails = 0
    for name, fn, expect, _reason, mutation in TESTS:
        if not mutation:
            continue
        out = run_one(fn, mutation)
        got = row_of(out)["state"]
        order = [s for s, v in mutation.items() if not v]
        red = (got != expect)
        print(f"{'PASS' if red else 'FAIL'} drop gate {','.join(order)} => {name}: "
              f"now reads {got} (expected the test to go RED)")
        if not red:
            mut_fails += 1
    if mut_fails:
        print(f"\n{mut_fails} mutation(s) did NOT go red — that gate is not load-bearing")
        return 1
    print("\nall three mutations go RED: gates 1, 2 and 3 are each load-bearing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
