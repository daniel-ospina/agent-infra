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

(a) a chain that RESOLVES to launchd with no host app            => UNVERIFIABLE: NOT AUTHORISED
    (host decision, #1207 option A) — the gates all pass and the canon says `idle`, so the row is
    measured-and-refused, never unmeasured. With the reopen seam ON it becomes PARKED-REAPABLE.
(a2) a chain with a hop the snapshot cannot see                     => UNVERIFIABLE: incomplete
    (#1207, verbatim: "Unknown/unparseable chain ⇒ report only, never reap")
(b) the same child under a fake login-shell ancestor              => KEEP-HUMAN
(c) zero CPU delta but the transcript GREW                        => LIVE   (progress beats CPU)
(d) a pid that vanished between the two reads                     => UNVERIFIABLE, no crash
(e) CPU advanced 120 s over the window                            => LIVE
(f) canon RECORD VETO: the lane's own store record is fresh       => UNVERIFIABLE, never `idle`
    (this is the finding the first draft failed: asserting `store_ok=True` made the canon's
    #947 record veto structurally unreachable, so a lane whose record says it just consumed
    input was reapable as `idle`)
plus: every state is reachable IN THE CONFIGURATION THAT AUTHORISES IT, PARKED-REAPABLE is
UNREACHABLE under the shipped default (the host decision), and the name-stamp parser is UTC.
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
def _init():
    """pid 1 in the snapshot: a REAL `ps` read always carries it, and without it every chain
    ends in `ancestry()`'s `<pid 1 not visible>` marker — which is the INCOMPLETE shape (a2),
    not the same thing as a chain that resolves and simply has no host app (a)."""
    return _row(1, 0, comm="launchd", args="/sbin/launchd", time_="00:00:01", etime="9-00:00:00")


def case_a(tmp) -> Box:
    """A sleeping `pi` at ppid 1, zero CPU delta, a 30 h-frozen transcript: every MEASUREMENT
    passes (gates 1+3 + canon `idle`) and the chain RESOLVES to launchd — but it carries no
    host app, which the recorded rule calls `unknown` and keeps report-only."""
    now = time.time()
    t = write_transcript(tmp, now - 30 * 3600)
    before = {"1": _init(), "100": _row(100, 1)}
    return Box(before, before, t, now - 5 * 3600,
               store=write_store(tmp, pid=100, start_s=now - 5 * 3600, cwd=tmp, fresh=False))


def case_a2(tmp) -> Box:
    """The SAME row, but a hop is missing from the snapshot: the walk records `<pid 1 not
    visible>`. `#1207`: an unparseable chain is report-only — a hop the read could not see may
    be hiding the human ancestor the gate exists to find."""
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
    ("(a) resolved chain, no host app: measured-and-NOT-AUTHORISED",
     case_a, "UNVERIFIABLE", "host-decision-hostless", None),
    ("(a2) chain INCOMPLETE (a hop the snapshot cannot see)",
     case_a2, "UNVERIFIABLE", "ancestry-incomplete", None),
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


@contextlib.contextmanager
def _reopen_seam(on=True):
    """The ONE reopen seam (#1207 option A). The shipped default is OFF; the mutation control
    and the reachability check run with it ON, because that is the only configuration in which
    a signal can happen — i.e. the only one where gates 1/2/3 are load-bearing at all."""
    was = mod.AUTHORISE_HOSTLESS_CHAINS
    mod.AUTHORISE_HOSTLESS_CHAINS = on
    try:
        yield
    finally:
        mod.AUTHORISE_HOSTLESS_CHAINS = was


def run_one(fn, gates=None):
    tmp = tempfile.mkdtemp(prefix="orphan-reap-test-")
    try:
        return fn(tmp).census(gates)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ── the APPLY path — the only code here that can signal a pid ─────────────────────────────
def _apply_run(box, live=None, post=None):
    """Exercise `_apply_parked` with `os.kill` REPLACED, so no real pid can be signalled.

    Three reads are controllable, because each has its own guard: the census's `before`, the
    pre-signal re-verification (`live`), and the post-signal verification (`post`). `{}` means
    an UNREADABLE read — the shape that used to print `verified gone` for every target.
    """
    # FOUR reads, in this order: the census's `before` and CPU-window `after`, then the
    # pre-signal re-verification (`live`) and the post-signal verification (`post`). `{}` means
    # an UNREADABLE read — the shape that used to print `verified gone` for every target.
    snaps = [box.rows[0], box.rows[1],
             box.rows[1] if live is None else live,
             box.rows[1] if post is None else post]
    calls = {"n": 0}

    def ps():
        snap = snaps[min(calls["n"], len(snaps) - 1)]
        calls["n"] += 1
        return {pid: dict(r) for pid, r in snap.items()}

    kills = []
    names = ("ps_pi_fields", "session_index", "_cwd_of_pid", "_stat", "time",
             "SESSIONS_DIR", "STORE_PATH")
    saved = {n: getattr(mod, n) for n in names}
    real_kill = os.kill
    mod.ps_pi_fields = ps
    mod.session_index = lambda sessions_dir=None: [(box.transcript, box.start_ts)]
    mod._cwd_of_pid = lambda pid: None
    mod._stat = box.stat
    mod.time = box.clock
    mod.SESSIONS_DIR = os.path.dirname(box.transcript)
    mod.STORE_PATH = box.store
    os.kill = lambda pid, sig: kills.append((int(pid), sig))
    buf = io.StringIO()
    try:
        with _reopen_seam(True), contextlib.redirect_stdout(buf):
            rc = mod.pi_census(20.0, apply=True, store_path=box.store)
    finally:
        os.kill = real_kill
        for n, v in saved.items():
            setattr(mod, n, v)
    return rc, buf.getvalue(), kills


def apply_path() -> int:
    """FOUR assertions on the only code in this file that can send a signal.

    Every other case runs `apply=False`, so the kill path — its incarnation/recycle refusals,
    and the two guards that keep an UNREADABLE `ps` read from reading as success — had no test
    that could go red if the guard were deleted. `os.kill` is replaced, so no pid is touched.
    """
    fails = 0
    tmp = tempfile.mkdtemp(prefix="orphan-reap-apply-")
    try:
        def check(name, rc, out, kills, want_rc, want_kills, must=(), must_not=()):
            nonlocal fails
            bad = [m for m in must if m not in out] + [m for m in must_not if m in out]
            ok = rc == want_rc and kills == want_kills and not bad
            print(f"{'PASS' if ok else 'FAIL'} {name}: rc={rc} (want {want_rc}), "
                  f"kills={kills} " + (f"— wrong: {bad}" if bad else ""))
            if not ok:
                fails += 1

        # (g1) the target is STILL in the post-signal read: rc 1, and never `verified gone`
        rc, out, kills = _apply_run(case_a(tmp), post=None)
        check("(g1) a target still present after the signal", rc, out, kills, 1, [(100, 15)],
              must=("STILL ALIVE",), must_not=("verified gone: 100",))

        # (g2) a readable post-signal read that no longer carries it: the one `verified gone`
        rc, out, kills = _apply_run(case_a(tmp), post={"1": _init()})
        check("(g2) a target verified gone", rc, out, kills, 0, [(100, 15)],
              must=("verified gone: 100",), must_not=("UNVERIFIABLE — the post-signal",))

        # (g3) an UNREADABLE post-signal read is NOT a reap: rc 2, no `verified gone`
        rc, out, kills = _apply_run(case_a(tmp), post={})
        check("(g3) the POST-signal read returned nothing", rc, out, kills, 2, [(100, 15)],
              must=("UNVERIFIABLE — the post-signal",), must_not=("verified gone: 100",))

        # (g4) an UNREADABLE pre-signal read cannot re-verify identity: nothing is signalled
        rc, out, kills = _apply_run(case_a(tmp), live={})
        check("(g4) the PRE-signal read returned nothing", rc, out, kills, 2, [],
              must=("UNVERIFIABLE — the pre-signal",),
              must_not=("verified gone: 100", "SIGTERM ->"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return fails


def suite(mutate: dict | None = None) -> int:
    # the mutation control only means something where a signal is POSSIBLE, so it runs through
    # the reopen seam; the plain suite runs with the shipped default (seam OFF).
    with (_reopen_seam(True) if mutate else _reopen_seam(mod.AUTHORISE_HOSTLESS_CHAINS)):
        return _suite(mutate)


def _suite(mutate: dict | None = None) -> int:
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
    """Every state must be producible in the configuration that owns it — no state may be a
    decorative name, and no state may be reachable only by a fixture accident.

    TWO assertions, because the honest set differs by configuration: with the reopen seam ON all
    four are reachable, and under the SHIPPED default PARKED-REAPABLE must be UNREACHABLE — that
    is what the host decision (#1207 option A) means, and it is the pin that stops the state
    quietly becoming authorised again.
    """
    def seen_with(seam: bool) -> set:
        seen = set()
        with _reopen_seam(seam):
            for _name, fn, _expect, _r, _m in TESTS:
                try:
                    seen.add(row_of(run_one(fn))["state"])
                except Exception:
                    pass
        return seen

    authorised = seen_with(True)
    shipped = seen_with(False)
    missing = [s for s in mod.POOL_STATES if s not in authorised]
    leak = "PARKED-REAPABLE" in shipped
    ok = not missing and not leak
    print(f"{'PASS' if ok else 'FAIL'} every state reachable where it is authorised: "
          f"seam-ON {sorted(authorised)}" + (f" · MISSING {missing}" if missing else ""))
    if leak:
        print("       ⛔ PARKED-REAPABLE is reachable under the SHIPPED default — the host "
              "decision (#1207 option A) is not being applied")
    print(f"{'PASS' if not leak else 'FAIL'} shipped default refuses to authorise (seam OFF): "
          f"{sorted(shipped)}")
    return 0 if ok else 1


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
    fails = suite(None) + four_states_reachable() + utc_stamp() + apply_path()
    if fails:
        print(f"\n{fails} test(s) FAILED")
        return 1
    print("\nall 10 gate tests PASS")

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
