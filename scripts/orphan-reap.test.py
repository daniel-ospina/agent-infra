#!/usr/bin/env python3
"""orphan-reap.test.py — the gate suite for the `pi` pool (scripts/orphan-reap.py).

TWELVE tests, each with its own fixture, and THREE MUTATIONS that must go RED when a gate is
dropped. No live process is touched and nothing here can signal a pid: `ps`, the session index,
`stat`, the clock and the cmux hook store are all injected, and the only thing read back is the
census's own `--json` output (the census runs IN-PROCESS with `as_json=True`, so its JSON contract
is exercised; the ARGUMENT PARSER — `--pool`, `--pool all`, `--json` on the orphan pool — is not,
which is a named follow-up rather than a claim).
On top of those: EIGHT apply-path assertions (the only code here that signals), a
four-states-reachable pin, the name-stamp-is-UTC pin (four timezones), an empty-pool JSON
contract check, an UNREADABLE-`ps`-still-speaks-JSON check, and the fence-default pin against
the canon.
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
(g) the candidate is an ANCESTOR of this very reaper               => KEEP-HUMAN: self-ancestor
    (pins the arm; against every other fixture it is `always False`, so its removal was invisible)
(h) the REAL nested layout with a store record naming no `cwd`     => the canon must still find
    the transcript. `<sessions>/--<encoded-cwd>--/<stamp>_<sid>.jsonl` cannot be found by a FLAT
    search of the sessions root, and "a live writer with no store record" is the population the
    HOLDER append exists for — the reason assertion is the pin (without it: `jsonl-age-unknown`).
(i) a same-fence file with no readable `cwd` is NOT bound          => the cwd-less file is
    DROPPED and the row is decided by the matching one (`host-decision-hostless`); with the
    tolerant filter restored the pair is ambiguous and the row reads `ambiguous-binding`
(j) NO bindable session file, the lane PARKED                      => UNVERIFIABLE
    (`no-progress-channel:no-session-file`) — the documented blind spot's safe half
(k) NO bindable session file, the lane BUSY                        => LIVE (`cpu-advancing`)
    ─ (j)+(k) together are the doc's claim: the transcript gate abstains only on the PARKED row,
    because gate 1 is evaluated first. One row alone could be reordered without contradiction.
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
import re
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

    def __init__(self, rows_before, rows_after, transcript, start_ts, sizes=None, store=None,
                 sessions_dir=None, pid_cwd=None, sessions_index=None):
        self.rows = [rows_before, rows_after]
        self.ps_calls = 0
        self.stat_calls = 0
        self.transcript = transcript
        self.start_ts = start_ts
        self.sizes = sizes        # optional [size_before, size_after] to fake growth
        self.store = store
        # the SESSIONS ROOT, when it is not the transcript's own directory: pi nests a transcript
        # in `<sessions>/--<encoded-cwd>--/`, so a fixture that only ever writes FLAT cannot see
        # a reader that fails to descend (case_nested)
        self.sessions_dir = sessions_dir
        # the pid's cwd, when the case is ABOUT the cwd filter (None = `_cwd_of_pid` reads
        # nothing, which is what every other case wants: the filter is then skipped)
        self.pid_cwd = pid_cwd
        # an explicit [(path, stamp)] index, for a case that needs TWO same-fence candidates
        self.sessions_index = sessions_index
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
        mod.session_index = (lambda sessions_dir=None: list(self.sessions_index)
                             if self.sessions_index is not None
                             else [(self.transcript, self.start_ts)])
        mod._cwd_of_pid = (lambda pid: self.pid_cwd) if self.pid_cwd is not None \
            else (lambda pid: None)
        mod._stat = self.stat
        mod.time = self.clock          # sleep advances it: a post-window reference must drift
        mod.SESSIONS_DIR = self.sessions_dir or os.path.dirname(self.transcript)
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


def case_grew(tmp) -> Box:
    """The SAME authorised row, but its transcript GREW between the census and the signal.

    That is the lane consuming input inside the measurement->signal window: the stopped-reading
    that made the row PARKED-REAPABLE no longer holds, so the signal must be REFUSED. The census
    stats the transcript TWICE (pre-window ground truth, then the measurement) and both see it
    stopped; the third read — the signal-time re-read — sees it larger.
    """
    now = time.time()
    t = write_transcript(tmp, now - 30 * 3600)
    before = {"1": _init(), "100": _row(100, 1)}
    box = Box(before, before, t, now - 5 * 3600,
              store=write_store(tmp, pid=100, start_s=now - 5 * 3600, cwd=tmp, fresh=False))
    mtime = os.stat(t).st_mtime
    calls = {"n": 0}

    def stat_grows_at_signal(path):
        calls["n"] += 1
        return (mtime, 4096 if calls["n"] <= 2 else 4608)

    box.stat = stat_grows_at_signal
    return box


def case_store_fresh_at_signal(tmp) -> Box:
    """The SAME authorised row, but the HOOK STORE turns fresh between the census and the signal.

    This is the #947 leg on its own: a prompt was queued behind a tool, so the transcript has not
    been appended yet and a stat-only re-check sees nothing — only re-running the canon catches
    it. Pins the canon leg of `_authorisation_holds`; without this case deleting that leg leaves
    the whole suite green (a false PASS of the gate, not of the code).
    """
    now = time.time()
    start = now - 5 * 3600
    t = write_transcript(tmp, now - 30 * 3600)
    before = {"1": _init(), "100": _row(100, 1)}
    box = Box(before, before, t, start,
              store=write_store(tmp, pid=100, start_s=start, cwd=tmp, fresh=False))

    def on_ps(n):
        if n == 3:          # the PRE-signal read: the store becomes fresh here
            write_store(tmp, pid=100, start_s=start, cwd=tmp, fresh=True)

    box.on_ps = on_ps
    return box


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
    """A pid present in the first read and gone in the second: an incomplete read.

    The second snapshot keeps `init`, because a real `ps -Ao` ALWAYS lists at least init — an
    empty table is a broken read (`ps-unreadable`), not a world in which every pid vanished, and
    the census's own guard now says so. Only the row for pid 100 disappears.
    """
    now = time.time()
    t = write_transcript(tmp, now - 30 * 3600)
    before = {"1": _init(), "100": _row(100, 1)}
    return Box(before, {"1": _init()}, t, now - 5 * 3600,
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


def case_self(tmp) -> Box:
    """A candidate that is an ANCESTOR of this very process: the reaper must never classify the
    chain it runs under. `_self_chain` walks from `os.getpid()` through the snapshot, so the
    fixture makes pid 100 this process's parent — the shape a controller's own shell has.

    Pinned because the arm is `always False` against every other fixture (none of them carries
    this process's pid), so deleting `if ev.self_ancestor: return KEEP-HUMAN` left the suite green.
    """
    now = time.time()
    t = write_transcript(tmp, now - 30 * 3600)
    me = str(os.getpid())
    before = {me: _row(int(me), 100), "1": _init(), "100": _row(100, 1)}
    return Box(before, before, t, now - 5 * 3600,
               store=write_store(tmp, pid=100, start_s=now - 5 * 3600, cwd=tmp, fresh=False))


def case_nested(tmp) -> Box:
    """THE REAL LAYOUT, with a store record that names NO `cwd`: pi writes
    `<sessions>/--<encoded-cwd>--/<stamp>_<sid>.jsonl`, and the population this pool exists for is
    "a live writer with no store record" — the canon's `session_file_for` then searches the
    sessions root FLAT and cannot descend, so it lost the transcript and abstained
    `jsonl-age-unknown` while the row printed a measured age.

    Every other fixture writes the transcript FLAT inside the sessions root, which is why the
    suite could not see it. With the fix the reason is the host decision's; without it, it is
    `canon:unknown:jsonl-age-unknown` — the reason assertion is the pin.
    """
    now = time.time()
    nest = os.path.join(tmp, "--" + tmp.lstrip("/").replace("/", "-") + "--")
    os.makedirs(nest, exist_ok=True)
    t = write_transcript(nest, now - 30 * 3600)
    before = {"1": _init(), "100": _row(100, 1)}
    store = write_store(tmp, pid=100, start_s=now - 5 * 3600, cwd=tmp, fresh=False)
    with open(store, "r", encoding="utf-8") as fh:
        recs = json.load(fh)
    for rec in recs.values():
        rec.pop("cwd", None)      # a record that names no checkout — the HOLDER-append population
    with open(store, "w", encoding="utf-8") as fh:
        json.dump(recs, fh)
    return Box(before, before, t, now - 5 * 3600, store=store, sessions_dir=tmp)


def case_foreign_cwd(tmp) -> Box:
    """A same-fence session file with NO readable `cwd` must not be bound for a pid whose cwd IS
    known.

    `_session_cwd(p) in (None, cwd)` accepted such a file for ANY pid — the one fail-open default
    in the binding rule — and `session_index` globs every project subdirectory, so a foreign
    checkout's transcript could supply this row's gate-3 age and own median gap. Both files are
    inside the fence, so only the REASON distinguishes which one was bound:
      * the matching file (readable `cwd` == the pid's) is 30 h old  => bound, so the host decision
        decides the row: `host-decision-hostless`;
      * the `cwd`-less file is 1 h old => it must be DROPPED. If it is kept, the pair is
        `ambiguous-binding` — which is exactly what this case reads as when the tolerant filter is
        restored (verified by deletion mutant).
    """
    now = time.time()
    start = now - 5 * 3600
    t = write_transcript(tmp, now - 30 * 3600)
    foreign = os.path.join(tmp, "%s_%s.jsonl" % (_stamp_name(start), "ffffffff-0000-0000-0000-000000000000"))
    with open(t, "r", encoding="utf-8") as fh:
        lines = fh.readlines()
    first = json.loads(lines[0])
    first.pop("cwd", None)          # the foreign file records no checkout
    lines[0] = json.dumps(first) + "\n"
    with open(foreign, "w", encoding="utf-8") as fh:
        fh.writelines(lines)
    os.utime(foreign, (now - 3600, now - 3600))
    before = {"1": _init(), "100": _row(100, 1)}
    return Box(before, before, t, start,
               store=write_store(tmp, pid=100, start_s=start, cwd=tmp, fresh=False),
               sessions_dir=tmp, pid_cwd=tmp,
               sessions_index=[(t, start), (foreign, start)])


def case_foreign_cwd_unreadable(tmp) -> Box:
    """The pid's OWN `cwd` cannot be read (another uid / a refused `lsof`) — the file side must
    STILL be fail-closed, so a `cwd`-less same-fence file is never bound.

    The cwd filter used to sit INSIDE `if cwd is not None:`, so an unreadable pid cwd skipped it
    for BOTH sides: a transcript with no readable `cwd` — which `session_index` offers from every
    project subdirectory — was accepted for any pid and could supply this row's gate-3 age and own
    gap, while `binding_detail` showed nothing about the unchecked cwd. Case (i) covers the pid
    side when it IS readable (`pid_cwd=tmp`); this is the branch it could not see.

    The REASON is the pin: with the file dropped the row abstains `no-progress-channel:` +
    `no-session-file`; while the filter was skipped the foreign file bound and the row abstained
    for the host decision instead (`host-decision-hostless`) — a bound file is a different reason.
    `pid_cwd=None` is exactly the injected `_cwd_of_pid -> None` read.
    """
    now = time.time()
    start = now - 5 * 3600
    t = write_transcript(tmp, now - 30 * 3600)
    foreign = os.path.join(tmp, "%s_%s.jsonl" % (
        _stamp_name(start), "eeeeeeee-0000-0000-0000-000000000000"))
    with open(t, "r", encoding="utf-8") as fh:
        lines = fh.readlines()
    first = json.loads(lines[0])
    first.pop("cwd", None)          # the foreign file records no checkout
    lines[0] = json.dumps(first) + "\n"
    with open(foreign, "w", encoding="utf-8") as fh:
        fh.writelines(lines)
    os.utime(foreign, (now - 30 * 3600, now - 30 * 3600))
    before = {"1": _init(), "100": _row(100, 1)}
    return Box(before, before, t, start,
               store=write_store(tmp, pid=100, start_s=start, cwd=tmp, fresh=False),
               sessions_dir=tmp, pid_cwd=None,
               sessions_index=[(foreign, start)])


def case_zombie(tmp) -> Box:
    """The after-sample row is a ZOMBIE (`stat` starts with `Z`) — an abstention, never a verdict.

    A zombie keeps its comm and its `etime` and `os.kill` on it returns 0, so every other reading
    in this file would accept it as a live process. `pi_verdict`'s `zombie_after` arm exists for
    exactly that, and until this case NO fixture ever set `stat="Z"` — deleting the arm left the
    suite green. The survivor check's matching zombie leg is pinned by (g9).
    """
    now = time.time()
    t = write_transcript(tmp, now - 30 * 3600)
    before = {"1": _init(), "100": _row(100, 1)}
    after = {"1": _init(), "100": _row(100, 1, stat="Z")}
    return Box(before, after, t, now - 5 * 3600,
               store=write_store(tmp, pid=100, start_s=now - 5 * 3600, cwd=tmp, fresh=False),
               sessions_dir=tmp)


def case_recycled_mid_read(tmp) -> Box:
    """`etime` jumped BACKWARDS between the two census reads — a recycle INSIDE the sample window.

    The row's binding and its gate-3 age are measured off the BEFORE read, so in this shape they
    describe a process that no longer exists, and the pid now belongs to a fresh `pi`. The
    signal-time fence could not see it: it compares the after-read with the signal-time read, and
    BOTH are the new process. So the census itself must refuse the measurement — the after-read's
    `etime` (10 s) being lower than the before-read's (5 h) is the signature.

    The REASON is the pin: while this went undetected the row read `PARKED-REAPABLE`, i.e. it was
    a signal target; it must abstain as `recycled-mid-read`. (g10) pins the signal path.
    """
    now = time.time()
    t = write_transcript(tmp, now - 30 * 3600)
    before = {"1": _init(), "100": _row(100, 1, etime="05:00:00")}
    after = {"1": _init(), "100": _row(100, 1, etime="00:00:10")}
    return Box(before, after, t, now - 5 * 3600,
               store=write_store(tmp, pid=100, start_s=now - 5 * 3600, cwd=tmp, fresh=False),
               sessions_dir=tmp)


def case_unbound(tmp) -> Box:
    """NO bindable session file and a ZERO CPU delta — the documented blind spot, PARKED half.

    `docs/ops/fleet-liveness.md` now guarantees this row abstains as
    `no-progress-channel:<binding>` and never as "nothing to reap", and until this case that
    guarantee had no pin (an empty session index is the shape a print-mode / `task` child leaves).
    """
    now = time.time()
    t = write_transcript(tmp, now - 30 * 3600)
    before = {"1": _init(), "100": _row(100, 1)}
    return Box(before, before, t, now - 5 * 3600,
               store=write_store(tmp, pid=100, start_s=now - 5 * 3600, cwd=tmp, fresh=False),
               sessions_dir=tmp, sessions_index=[])


def case_unbound_busy(tmp) -> Box:
    """NO bindable session file, but the CPU is ADVANCING — the blind spot's BUSY half.

    This is the half the doc used to get WRONG (it claimed such a row could never read `LIVE`):
    gate 1 is evaluated before the transcript gate, so a busy unbound lane is `LIVE` / 
    `cpu-advancing`. Pinned so a future reordering of the gates cannot silently contradict the
    doc a second time — the pairing (j)+(k) is the statement, not either row alone.
    """
    now = time.time()
    t = write_transcript(tmp, now - 30 * 3600)
    before = {"1": _init(), "100": _row(100, 1, time_="00:01:00")}
    after = {"1": _init(), "100": _row(100, 1, time_="00:03:00")}
    return Box(before, after, t, now - 5 * 3600,
               store=write_store(tmp, pid=100, start_s=now - 5 * 3600, cwd=tmp, fresh=False),
               sessions_dir=tmp, sessions_index=[])


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
    ("(g) the candidate is an ANCESTOR of this reaper",
     case_self, "KEEP-HUMAN", "self-ancestor", None),
    ("(h) the real nested layout, store record naming no `cwd`",
     case_nested, "UNVERIFIABLE", "host-decision-hostless", None),
    ("(i) a same-fence file with no readable `cwd` is NOT bound",
     case_foreign_cwd, "UNVERIFIABLE", "host-decision-hostless", None),
    ("(i2) …and it is STILL not bound when the pid's own `cwd` is UNREADABLE",
     case_foreign_cwd_unreadable, "UNVERIFIABLE", "no-progress-channel:no-session-file", None),
    ("(j) no bindable session file, PARKED (the documented blind spot)",
     case_unbound, "UNVERIFIABLE", "no-progress-channel:no-session-file", None),
    ("(k) no bindable session file, BUSY — gate 1 still reads LIVE",
     case_unbound_busy, "LIVE", "cpu-advancing", None),
    ("(l) the after-sample row is a ZOMBIE (`stat` = Z) — abstain, never a verdict",
     case_zombie, "UNVERIFIABLE", "zombie", None),
    ("(m) `etime` moved BACKWARDS between the two census reads — recycled inside the window",
     case_recycled_mid_read, "UNVERIFIABLE", "recycled-mid-read", None),
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

    FOUR reads are controllable, in this order, because each has its own guard: the census's
    `before`, the CPU-window `after`, the pre-signal re-verification (`live`), and the post-signal
    verification (`post`). An empty mapping means an UNREADABLE read — the shape that used to
    print `verified gone` for every target — and the census guards all four with `if not <read>`,
    never `is None`, so the reading cannot be re-admitted by a change to `ps_pi_fields`.
    """
    snaps = [box.rows[0], box.rows[1],
             box.rows[1] if live is None else live,
             box.rows[1] if post is None else post]
    calls = {"n": 0}

    def ps():
        n = calls["n"]
        calls["n"] += 1
        hook = getattr(box, "on_ps", None)
        if hook is not None:
            hook(n + 1)
        snap = snaps[min(n, len(snaps) - 1)]
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
    """EIGHT assertions on the only code in this file that can send a signal.

    Every other case runs `apply=False`, so the kill path — its incarnation/recycle refusals,
    and the two guards that keep an UNREADABLE `ps` read from reading as success — had no test
    that could go red if the guard were deleted. `os.kill` is replaced, so no pid is touched.

    (g7)/(g8) exist because the docstring above was TRUE and the suite did not yet deliver it:
    g1 posts the IDENTICAL row, so `_same_incarnation` and the `is_pi(cur)` re-check could each
    be deleted with every assertion still passing (verified by deletion mutant). They are the two
    arms that stop a RECYCLED pid receiving a signal meant for a corpse.
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

        # (g6) the HOOK STORE turns fresh before the signal, while the transcript is untouched: only
        # the canon leg can see it. Pins `_authorisation_holds`'s store re-read — without this case,
        # deleting that leg leaves g1-g5 green and restores the #947 fail-open silently.
        rc, out, kills = _apply_run(case_store_fresh_at_signal(tmp))
        check("(g6) the store turned fresh before the signal", rc, out, kills, 0, [],
              must=("REFUSED: the canon verdict is no longer `idle`", "not signalled: 100"),
              must_not=("SIGTERM ->", "STILL ALIVE", "survived SIGTERM"))

        # (g4) an UNREADABLE pre-signal read cannot re-verify identity: nothing is signalled
        rc, out, kills = _apply_run(case_a(tmp), live={})
        check("(g4) the PRE-signal read returned nothing", rc, out, kills, 2, [],
              must=("UNVERIFIABLE — the pre-signal",),
              must_not=("verified gone: 100", "SIGTERM ->"))

        # (g5) the TRANSCRIPT GREW in the measurement->signal window: the reading that authorised
        # the row is stale, so nothing is signalled — and a refused row is NOT a survivor. This
        # pins BOTH review-cycle-1 defects: identity-only re-verification (the kill would have
        # been sent) and the survivor accounting (a refused pid used to print STILL ALIVE and
        # exit 1 although no SIGTERM was ever sent to it).
        rc, out, kills = _apply_run(case_grew(tmp))
        check("(g5) the transcript grew before the signal", rc, out, kills, 0, [],
              must=("REFUSED: the transcript CHANGED", "not signalled: 100"),
              must_not=("SIGTERM ->", "STILL ALIVE", "survived SIGTERM"))

        # (g7) the pid survives but is no longer a `pi` — the recycle's other half. Pins the
        # `is_pi(cur)` re-check: deleting it signals a recycled non-pi process.
        rc, out, kills = _apply_run(
            case_a(tmp),
            live={"1": _init(), "100": _row(100, 1, comm="python3", args="python3")})
        check("(g7) the pid is no longer a `pi` (recycled)", rc, out, kills, 0, [],
              must=("REFUSED: the pid is no longer a `pi`",),
              must_not=("SIGTERM ->", "STILL ALIVE"))

        # (g8) the SAME pid, still a `pi`, but a NEWER process: `etime` moved BACKWARDS, which is
        # precisely the recycle signature. Pins `_same_incarnation` — g1 posts the identical row,
        # so without this case that guard can be deleted and every assertion still passes.
        rc, out, kills = _apply_run(
            case_a(tmp), live={"1": _init(), "100": _row(100, 1, etime="00:00:10")})
        check("(g8) the pid is a NEWER incarnation (etime moved backwards)", rc, out, kills, 0, [],
              must=("REFUSED: incarnation changed",),
              must_not=("SIGTERM ->", "STILL ALIVE"))

        # (g9) the target survives but is a ZOMBIE: it keeps its comm and `etime`, and `os.kill`
        # on a `Z` returns 0, so presence + `is_pi` alone would report a process that has ALREADY
        # EXITED as a survivor and exit 1. Pins the `not stat.startswith("Z")` leg — before this
        # case no fixture set `stat="Z"`, so that leg could be deleted with the suite green.
        rc, out, kills = _apply_run(
            case_a(tmp), post={"1": _init(), "100": _row(100, 1, stat="Z")})
        check("(g9) the survivor is a ZOMBIE (already exited)", rc, out, kills, 0, [(100, 15)],
              must=("verified gone: 100",),
              must_not=("STILL ALIVE", "survived SIGTERM"))

        # (g10) a pid recycled BETWEEN the two census reads must never reach a signal: the row's
        # binding and age were measured off the dead process, so it is not a target at all.
        rc, out, kills = _apply_run(case_recycled_mid_read(tmp))
        check("(g10) the pid was recycled inside the sample window", rc, out, kills, 0, [],
              must_not=("SIGTERM ->", "STILL ALIVE", "verified gone: 100"))

        # (g11) `_same_incarnation` must fence against the incarnation the row was MEASURED on,
        # not only its after-read. Here the after-read and the signal-time read agree (both 12 s)
        # — so the after-read comparison passes — but the row was measured on a 5 h process.
        # Pins the measured-etime floor: without it this returns True and a recycled pid is killed.
        recycled = {"etime": "05:00:00", "etime_after": "00:00:12"}
        cur = _row(100, 1, etime="00:00:12")
        ok = mod._same_incarnation(recycled, cur)
        print(f"{'PASS' if not ok else 'FAIL'} (g11) `_same_incarnation` rejects a row measured "
              f"on an older incarnation than its after-read: {ok}")
        if ok:
            fails += 1
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


def empty_pool_json() -> int:
    """`--pool pi --json` on a box with no `pi` must still emit JSON (and exit 0).

    The empty pool is the single most common input, and it printed a PROSE sentence on stdout
    before the `as_json` branch was reached — so a caller's `| jq` failed to parse exactly when
    the answer was "0 pi, nothing to reap", while the exit code said success. The machine-readable
    mode may not be destroyed by its own trivial case any more than by its own action.
    """
    saved = {n: getattr(mod, n) for n in ("ps_pi_fields",)}
    buf = io.StringIO()
    mod.ps_pi_fields = lambda: {"1": _init()}          # a real, EMPTY read: no `pi` in the table
    try:
        with contextlib.redirect_stdout(buf):
            rc = mod.pi_census(1.0, apply=False, as_json=True)
    finally:
        for n, v in saved.items():
            setattr(mod, n, v)
    raw = buf.getvalue()
    try:
        doc = json.loads(raw)
    except ValueError:
        print(f"FAIL the empty pool's `--json` emitted non-JSON on stdout: {raw.strip()[:120]!r}")
        return 1
    ok = (rc == 0 and doc.get("rows") == []
          and doc.get("counts") == {s: 0 for s in mod.POOL_STATES})
    print(f"{'PASS' if ok else 'FAIL'} the empty `pi` pool emits a JSON census "
          f"(rc={rc}, counts={doc.get('counts')}, rows={doc.get('rows')})")
    return 0 if ok else 1


def unreadable_json() -> int:
    """The `no census was read` returns must ALSO speak JSON in `--json` mode (rc 2).

    The fixed empty-pool path was only one of three; the FAILED reads still printed a prose
    sentence on stdout, so a consumer got a non-JSON document exactly when the read failed. Both
    are pinned here, with their own `error` code, and `counts: null` so a failed read is never
    mistakable for a real census of zero.

    The THIRD case is the CPU-window read, which had NO guard at all (review finding on #2334,
    cycle 2): `after = ps_pi_fields()` was read straight into `after.get(pid)`, so a failed second
    read reported every live lane as `vanished-mid-read` and exited 0 — and `--apply` would then
    announce that the reapable set was EMPTY. It is pinned separately because it is the SECOND
    call, and a stub that fails only there is the only way to reach that arm.
    """
    fails = 0
    def _second_read_fails():
        """A successful first read (init + a `pi`), then a FAILED one."""
        calls = {"n": 0}
        def read():
            calls["n"] += 1
            if calls["n"] == 1:
                return {"1": _init(), "100": _row(100, 1)}
            return None
        return read

    def _second_read_is_an_empty_table():
        """A successful first read, then an EMPTY table.

        The guard is `if not after:` — not `is None` — precisely so this shape cannot be read as
        "every pid vanished". A real `ps -Ao` always carries init, so an empty table is a broken
        read however the reader spells it; tightening the guard to `is None` re-opens cycle 2's
        defect for any future edit that lets `{}` through, and this case goes red when it does.
        """
        calls = {"n": 0}
        def read():
            calls["n"] += 1
            if calls["n"] == 1:
                return {"1": _init(), "100": _row(100, 1)}
            return {}
        return read

    for label, patch, want in (
            ("`ps` returned nothing", {"ps_pi_fields": lambda: None}, "ps-unreadable"),
            ("the CPU-window `ps` read failed",
             {"ps_pi_fields": _second_read_fails()}, "ps-unreadable"),
            ("the CPU-window `ps` read came back EMPTY",
             {"ps_pi_fields": _second_read_is_an_empty_table()}, "ps-unreadable"),
            ("the verdict module is unimportable",
             {"fleet_liveness": lambda: None}, "liveness-unimportable"),
    ):
        saved = {n: getattr(mod, n) for n in patch}
        buf = io.StringIO()
        for n, v in patch.items():
            setattr(mod, n, v)
        try:
            with contextlib.redirect_stdout(buf):
                rc = mod.pi_census(1.0, apply=False, as_json=True)
        finally:
            for n, v in saved.items():
                setattr(mod, n, v)
        raw = buf.getvalue()
        try:
            doc = json.loads(raw)
            ok = rc == 2 and doc.get("error") == want and doc.get("counts") is None
        except ValueError:
            ok, doc = False, {}
        print(f"{'PASS' if ok else 'FAIL'} `--json` still speaks JSON when {label} "
              f"(rc={rc}, error={doc.get('error')!r}, counts={doc.get('counts')!r})")
        if not ok:
            fails += 1
    return fails


def fence_matches_canon() -> int:
    """The fence default is the CANON's, and the two are pinned together.

    `FENCE_S` must carry a literal fallback (a Python module cannot read the bash `:-` default at
    run time), so a test is the only thing keeping `pid-identity.sh:68` and this file from
    drifting — and a wider fence here is a silently weaker identity rule the canon cannot see.
    """
    path = os.path.join(ROOT, "scripts", "lib", "pid-identity.sh")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            src = fh.read()
    except OSError as exc:
        print(f"FAIL the canon's fence default could not be read ({exc})")
        return 1
    m = re.search(r"FENCE_TOLERANCE_SECONDS:-([0-9.]+)", src)
    if not m:
        print(f"FAIL {path}: no `${{FENCE_TOLERANCE_SECONDS:-N}}` default found")
        return 1
    want = float(m.group(1))
    ok = want == mod.FENCE_DEFAULT_S
    print(f"{'PASS' if ok else 'FAIL'} the fence default mirrors the canon "
          f"(pid-identity.sh {want:g} s vs this file {mod.FENCE_DEFAULT_S:g} s)")
    return 0 if ok else 1


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    print("── suite ──")
    fails = (suite(None) + four_states_reachable() + utc_stamp() + apply_path()
             + empty_pool_json() + unreadable_json() + fence_matches_canon())
    if fails:
        print(f"\n{fails} test(s) FAILED")
        return 1
    print("\nall gate tests PASS")

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
