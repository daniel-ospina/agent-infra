#!/usr/bin/env python3
"""tools/fleet/successor_preflight.test.py — hermetic suite for #1317.

The successor preflight decides whether a successor lane may be dispatched to a
worktree. The failure it exists to prevent is expensive and asymmetric: a false
``PREDECESSOR-GONE`` puts a second lane on a live unit (the #1317 incident — an
entire lane's context, a branch moving under a review, and the risk of two lanes
writing one branch), while a false refusal costs a delay a human can read past in
the proof block. Every leg here therefore pins the SAFE direction of the read it
exercises, and the red controls prove each leg can go red.

    python3 tools/fleet/successor_preflight.test.py
    python3 tools/fleet/successor_preflight.test.py --red-control

RED CONTROL — fifteen mutations, each run against the leg that must catch it (a
mutation the suite does not catch is reported as a suite FAILURE):

  * drop the live-process check        -> LIVE-PROCESS red
  * drop the live-lane check           -> LIVE-LANE red
  * drop the recent-cmux check         -> LIVE-CMUX red
  * unreadable store becomes GONE      -> STORE-UNREADABLE red
  * unreadable process read becomes GONE -> PROCESS-UNREADABLE red
  * drop the realpath normalisation    -> REALPATH red
  * ignore the cmux recency window     -> CMUX-WINDOW red
  * read cmux cwd without matching it  -> OTHER-WORKTREE red
  * drop the shared liveness predicate (call every lane `dead`) -> LIVE-LANE red
  * accept a partial cwd read as complete -> PARTIAL-CWD-READ red
  * an unreadable cwd read becomes an omitted one -> PROC-READ-REFUSED red
  * drop the unlinked-cwd normalisation -> DELETED-CWD red
  * report a nonexistent worktree as GONE -> NO-WORKTREE red
  * accept a non-procfs root as the process table -> ROOT-NOT-PROCFS red
  * read an epoch-millis stamp as epoch seconds -> CMUX-WINDOW red

Zero-dep by construction: python3 + bash only. Every input is a temp fixture;
``pgrep``/``lsof``/``cmux``/``ps``/``date`` are hermetic shims, so nothing touches
the real fleet, the real store, the network, or the process table. The procfs is
hermetic too (a fake ``--proc-root``), so the ``/proc`` fallback is actually
exercised and no leg's verdict can depend on the host's ``/proc``.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_PATH = os.path.normpath(os.path.join(HERE, "successor_preflight.py"))
LIB_PATH = os.path.normpath(os.path.join(HERE, "..", "..", "scripts", "lib", "pid-identity.sh"))

NOW_S = 1_789_000_000
NOW_MS = NOW_S * 1000
PROBE_EPOCH = 1_760_000_000
PROBE_LSTART = "Thu Sep 18 14:40:00 2026"

WS = "11111111-1111-4111-8111-111111111111"
SID = "aaaaaaaa-0000-4000-8000-000000000001"
WS2 = "22222222-2222-4222-8222-222222222222"
SID2 = "bbbbbbbb-0000-4000-8000-000000000002"
PID_DEAD = 2222
PID_LIVE = 1111
PID_OTHER = 3333

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print("  ✅ %s" % msg)


def bad(msg):
    global FAIL
    FAIL += 1
    print("  ❌ %s" % msg)


def assert_eq(got, want, msg):
    if got == want:
        ok(msg)
    else:
        bad("%s (got: %r, want: %r)" % (msg, got, want))


def assert_in(needle, haystack, msg):
    if needle in haystack:
        ok(msg)
    else:
        bad("%s (missing %r in:\n%s)" % (msg, needle, haystack))


def assert_not_in(needle, haystack, msg):
    if needle not in haystack:
        ok(msg)
    else:
        bad("%s (unexpected %r)" % (msg, needle))


# ── shims ────────────────────────────────────────────────────────────────
PGREP_SHIM = """#!/usr/bin/env bash
[ -f "@PIDS@" ] || exit 1
read -r line < "@PIDS@" || exit 1
# `pgrep -x pi` would exit 1 on no match; the fixture file is the whole answer.
if [ -z "$(printf '%s' "$line" | tr -d ' \\n')" ]; then exit 1; fi
printf '%s\\n' "$line"
exit 0
"""

LSOF_SHIM = """#!/usr/bin/env bash
# `lsof -a -d cwd -Fn -p <csv>` — print `p<pid>`/`n<cwd>` for each mapped pid.
pids=""
while [ $# -gt 0 ]; do
  case "$1" in -p) pids="$2"; shift 2 ;; *) shift ;; esac
done
[ -f "@MAP@" ] || exit 1
rc=1
IFS=',' read -ra want <<< "$pids"
for p in "${want[@]}"; do
  cwd="$(awk -F'\\t' -v k="$p" '$1==k {print $2}' "@MAP@" | head -1)"
  if [ -n "$cwd" ]; then printf 'p%s\\nn%s\\n' "$p" "$cwd"; rc=0; fi
done
exit $rc
"""

CMUX_SHIM = """#!/usr/bin/env bash
[ -f "@JSON@" ] || exit 1
cat "@JSON@"
"""

PS_SHIM = """#!/usr/bin/env bash
[ "${1:-}" = "-axo" ] || exit 1
cat "@ROWS@"
"""

DATE_SHIM = """#!/usr/bin/env bash
arg=""
for a in "$@"; do
    case "$a" in %*|+%s|-j|-f|-d) continue ;; esac
    arg="$a"
done
if [ "$arg" = "Sat Jan  1 00:00:00 2000" ]; then echo 946684800; exit 0; fi
hit="$(awk -F'\\t' -v k="$arg" '$1==k {print $2}' "@LOOKUP@" | head -1)"
[ -n "$hit" ] && { echo "$hit"; exit 0; }
exit 1
"""


def record(sid, workspace, pid, *, cwd, updated_at=NOW_S, non_idle=True):
    return {
        "sessionId": sid,
        "workspaceId": workspace,
        "surfaceId": workspace,
        "pid": pid,
        "pidStartSeconds": PROBE_EPOCH,
        "cwd": cwd,
        "startedAt": updated_at - 3600,
        "updatedAt": updated_at,
        "agentLifecycle": "running" if non_idle else "idle",
        "runtimeStatus": "running" if non_idle else "idle",
        "priorProcessGenerations": [],
    }


def ps_row(pid):
    # pid ppid pgid tty lstart stat rss command — the pinned ps contract.
    return "%d 1 %d ttys001 %s S 1234 /usr/local/bin/pi" % (pid, pid, PROBE_LSTART)


class Fixture:
    """A hermetic fleet: store, sessions, shims, cmux roster, process reads."""

    def __init__(self, *, worktree, lanes=(), pids=(), cwd_map=None, ps_rows=None,
                 cmux_rows=None, cmux_readable=True):
        self.dir = tempfile.mkdtemp(prefix="succ-pre-test-")
        self.worktree = worktree
        # The target MUST exist: a nonexistent --worktree is now an environment
        # error (exit 2, nothing decided), never a GONE proof. The old fixture
        # never created it, which is exactly how that gap went unnoticed.
        os.makedirs(worktree, exist_ok=True)
        # The procfs is ALWAYS hermetic, so (a) the /proc fallback is reachable in
        # the suite at all — the old suite let every leg answer through the lsof
        # shim, so the fallback was never executed — and (b) no leg's verdict can
        # depend on the host's real /proc.
        self.proc = os.path.join(self.dir, "proc")
        os.makedirs(self.proc, exist_ok=True)
        # A procfs identifies itself: the tool refuses to treat ENOENT as "the pid
        # is gone" against anything else (`_is_procfs`), so the fixture plants
        # `self` exactly as a real /proc has it. Without this the fixture would be
        # (correctly) refused as not-a-procfs.
        os.makedirs(os.path.join(self.proc, "self"), exist_ok=True)

        sessions = {}
        for sid, ws, rec in lanes:
            sessions[sid] = rec
        store = {"version": 1, "sessions": sessions}
        self.store = os.path.join(self.dir, "pi-hook-sessions.json")
        with open(self.store, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(store))

        self.sessions_dir = os.path.join(self.dir, "sessions")
        os.makedirs(self.sessions_dir, exist_ok=True)
        self.task_sessions = os.path.join(self.dir, "task-sessions")
        os.makedirs(self.task_sessions, exist_ok=True)
        self.cmux_state = os.path.join(self.dir, "cmux-state.json")
        with open(self.cmux_state, "w", encoding="utf-8") as fh:
            fh.write(json.dumps({"windows": [{"tabManager": {"workspaces": [
                {"workspaceId": ws} for _sid, ws, _rec in lanes]}}]}))

        # pgrep / lsof
        self.pids_file = os.path.join(self.dir, "pids")
        with open(self.pids_file, "w", encoding="utf-8") as fh:
            fh.write(" ".join(str(p) for p in pids) + "\n")
        self.lsof_map = os.path.join(self.dir, "lsof.map")
        with open(self.lsof_map, "w", encoding="utf-8") as fh:
            for pid, cwd in (cwd_map or {}).items():
                fh.write("%s\t%s\n" % (pid, cwd))
        self.pgrep = self._shim("pgrep", PGREP_SHIM.replace("@PIDS@", self.pids_file))
        self.lsof = self._shim("lsof", LSOF_SHIM.replace("@MAP@", self.lsof_map))

        # cmux
        self.cmux_json = os.path.join(self.dir, "cmux.json")
        if cmux_rows is not None:
            with open(self.cmux_json, "w", encoding="utf-8") as fh:
                fh.write(json.dumps(cmux_rows))
        if cmux_readable:
            self.cmux = self._shim("cmux", CMUX_SHIM.replace("@JSON@", self.cmux_json))
        else:
            self.cmux = os.path.join(self.dir, "no-such-cmux")

        # ps + date for the shared liveness predicate
        # The ps table must be NON-EMPTY or the shared probe reads the whole
        # read as unreadable (#1178 C3): every real table contains the probing
        # process. PID_OTHER is the standing sentinel for "a table was read".
        rows_src = [ps_row(PID_OTHER)] if ps_rows is None else list(ps_rows)
        rows = os.path.join(self.dir, "ps.rows")
        with open(rows, "w", encoding="utf-8") as fh:
            fh.write("\n".join(rows_src) + "\n")
        self.ps = self._shim("ps", PS_SHIM.replace("@ROWS@", rows))
        look = os.path.join(self.dir, "date.lookup")
        with open(look, "w", encoding="utf-8") as fh:
            fh.write("%s\t%d\n" % (PROBE_LSTART, PROBE_EPOCH))
        self.date = self._shim("date", DATE_SHIM.replace("@LOOKUP@", look))

    def _shim(self, name, body):
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        os.chmod(path, 0o755)
        return path

    def proc_cwd(self, pid, value, kind="symlink"):
        """Plant `<proc>/<pid>/cwd`.

        ``symlink`` is the readable shape. ``file`` is the REFUSED shape: the
        path exists but is not a symlink, so ``os.readlink`` raises ``EINVAL``
        (an ``OSError`` that is not ``FileNotFoundError``) — the same class as an
        ``EACCES`` under ``hidepid``, and deterministic regardless of the uid the
        suite runs as (a chmod-based fixture would pass under root).
        """
        d = os.path.join(self.proc, str(pid))
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, "cwd")
        if kind == "symlink":
            os.symlink(value, p)
        else:
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(value)

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def run_preflight(fx, *args, module=None):
    module = module or MODULE_PATH
    cmd = [sys.executable, module,
           "--worktree", fx.worktree,
           "--store", fx.store,
           "--sessions-dir", fx.sessions_dir,
           "--task-sessions", fx.task_sessions,
           "--cmux-state", fx.cmux_state,
           "--pgrep-bin", fx.pgrep,
           "--lsof-bin", fx.lsof,
           "--cmux-bin", fx.cmux,
           "--proc-root", fx.proc,
           "--now", str(NOW_S)]
    cmd.extend(args)
    env = dict(os.environ)
    env.pop("PS_BIN", None)
    env.pop("LANE_LIVENESS_PS_CACHE", None)
    env.update({
        "LANE_LIVENESS_PS_REAL": fx.ps,
        "DATE_BIN": fx.date,
        "PI_PID_IDENTITY_LIB": LIB_PATH,
    })
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


# ── tests ────────────────────────────────────────────────────────────────
TESTS = []


def test(name):
    def deco(fn):
        TESTS.append((name, fn))
        return fn
    return deco


@test("GONE")
def t_gone(module):
    """A dead predecessor on the worktree: the successor may be dispatched."""
    wt = os.path.join(tempfile.gettempdir(), "succ-gone-wt")
    fx = Fixture(worktree=wt,
                 lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 ps_rows=[ps_row(PID_OTHER)],           # PID_DEAD is gone
                 cmux_rows=[{"id": WS2, "current_directory": "/elsewhere"}])
    try:
        for mod in (module,):
            rc, out = run_preflight(fx, module=mod)
            assert_eq(rc, 0, "rc 0 = dispatch a successor")
            assert_in("verdict: PREDECESSOR-GONE", out, "verdict is GONE")
            assert_in("read-at:", out, "the proof carries its reading timestamp")
            assert_in("state=dead", out, "the dead lane record is cited")
            assert_in("no live pi rooted in this worktree", out, "the process read is stated")
    finally:
        fx.close()


@test("LIVE-PROCESS")
def t_live_process(module):
    """A live pi rooted in the worktree wins over a store that says dead."""
    wt = os.path.join(tempfile.gettempdir(), "succ-liveproc-wt")
    fx = Fixture(worktree=wt,
                 lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 pids=[PID_OTHER],
                 cwd_map={PID_OTHER: wt},
                 ps_rows=[ps_row(PID_OTHER)],
                 cmux_rows=[])
    try:
        rc, out = run_preflight(fx, module=module)
        assert_eq(rc, 3, "rc 3 = do not dispatch a successor")
        assert_in("verdict: PREDECESSOR-LIVE", out, "verdict is LIVE")
        assert_in("live-pi-cwd:%d" % PID_OTHER, out, "the live pid is the named witness")
    finally:
        fx.close()


@test("LIVE-LANE")
def t_live_lane(module):
    """A lane record on the worktree that is not `dead` blocks the successor."""
    wt = os.path.join(tempfile.gettempdir(), "succ-livelane-wt")
    fx = Fixture(worktree=wt,
                 lanes=[(SID, WS, record(SID, WS, PID_LIVE, cwd=wt))],
                 ps_rows=[ps_row(PID_LIVE)],
                 cmux_rows=[])
    try:
        rc, out = run_preflight(fx, module=module)
        assert_eq(rc, 3, "rc 3 = the predecessor is alive")
        assert_in("live-lane-record:", out, "the non-dead lane record is the named witness")
        assert_in("state=running-quiet", out, "the shared predicate produced the state")
    finally:
        fx.close()


@test("LIVE-CMUX")
def t_live_cmux(module):
    """Recent cmux activity on the worktree blocks even with no live process."""
    wt = os.path.join(tempfile.gettempdir(), "succ-livecmux-wt")
    fx = Fixture(worktree=wt,
                 lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 cmux_rows=[{"id": WS, "current_directory": wt,
                             "latest_submitted_at": NOW_S - 60,
                             "latest_submitted_message": "continue the review"}])
    try:
        rc, out = run_preflight(fx, module=module)
        assert_eq(rc, 3, "rc 3 = recent activity means do not dispatch")
        assert_in("recent-cmux-inbound:", out, "the recent workspace is the named witness")
    finally:
        fx.close()


@test("CMUX-WINDOW")
def t_cmux_window(module):
    """Activity older than the window is not activity (the window is real).

    The second row is deliberately stamped in epoch MILLIS and is STALE: a
    millis value the code fails to convert is a *future* timestamp, so a merely
    "recent" millis row cannot discriminate the conversion at all (a cycle-2
    finding — the leg passed unchanged with `/1000.0` removed). A stale millis
    row does discriminate, and the JSON assertion pins the conversion itself.
    """
    wt = os.path.join(tempfile.gettempdir(), "succ-window-wt")
    fx = Fixture(worktree=wt,
                 lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 cmux_rows=[{"id": WS, "current_directory": wt,
                             "updated_at": NOW_S - 4000},
                            {"id": WS2, "current_directory": wt,
                             "updated_at": (NOW_S - 4000) * 1000}])
    try:
        rc, out = run_preflight(fx, "--recent-s", "900", "--json", module=module)
        assert_eq(rc, 0, "rc 0 = stale activity does not block")
        doc = json.loads(out)
        assert_eq(doc["verdict"], "PREDECESSOR-GONE", "verdict is GONE")
        assert_eq([a["recent"] for a in doc["cmux_activity"]], [False, False],
                  "neither the stale seconds row nor the stale millis row is recent")
        assert_eq(doc["cmux_activity"][1]["updated_at"], NOW_S - 4000,
                  "the millis stamp is converted to seconds, not read as a future one")
    finally:
        fx.close()


@test("ROOT-NOT-PROCFS")
def t_root_not_procfs(module):
    """A root that is not a procfs cannot make an omitted pid read as gone.

    `ENOENT` means "the pid is gone" only against a real process table. A cycle-2
    finding (P1): with an ambient `SUCCESSOR_PROC_ROOT` pointing at any empty
    directory, a live pid omitted by lsof was 'completed' by that directory's
    silence and reported GONE.
    """
    wt = os.path.join(tempfile.gettempdir(), "succ-notprocfs-wt")
    plain = tempfile.mkdtemp(prefix="succ-plain-root-")
    fx = Fixture(worktree=wt, lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 pids=[PID_OTHER], cmux_rows=[])
    try:
        rc, out = run_preflight(fx, "--lsof-bin", os.path.join(fx.dir, "no-lsof"),
                                "--proc-root", plain, module=module)
        assert_eq(rc, 4, "rc 4 = a non-procfs root may not answer for the process table")
        assert_in("verdict: UNKNOWN", out, "verdict is UNKNOWN")
    finally:
        fx.close()
        shutil.rmtree(plain, ignore_errors=True)


@test("OTHER-WORKTREE")
def t_other_worktree(module):
    """A live pi in ANOTHER worktree must not block this one."""
    wt = os.path.join(tempfile.gettempdir(), "succ-scope-wt")
    other = os.path.join(tempfile.gettempdir(), "succ-scope-other")
    fx = Fixture(worktree=wt,
                 lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 pids=[PID_OTHER],
                 cwd_map={PID_OTHER: other},
                 ps_rows=[ps_row(PID_OTHER)],
                 cmux_rows=[{"id": WS2, "current_directory": other,
                             "latest_submitted_at": NOW_S - 10}])
    try:
        rc, out = run_preflight(fx, module=module)
        assert_eq(rc, 0, "rc 0 = another worktree's lane is not this one's predecessor")
        assert_in("verdict: PREDECESSOR-GONE", out, "verdict is GONE")
    finally:
        fx.close()


@test("REALPATH")
def t_realpath(module):
    """A symlinked target path and a real record cwd are the SAME worktree."""
    base = tempfile.mkdtemp(prefix="succ-real-")
    try:
        real = os.path.join(base, "real")
        os.makedirs(real)
        link = os.path.join(base, "link")
        os.symlink(real, link)
        fx = Fixture(worktree=link,
                     lanes=[(SID, WS, record(SID, WS, PID_LIVE, cwd=real))],
                     ps_rows=[ps_row(PID_LIVE)],
                     cmux_rows=[])
        try:
            rc, out = run_preflight(fx, module=module)
            assert_eq(rc, 3, "rc 3 = the lane on the real path is found via the symlink")
            assert_in("live-lane-record:", out, "the live lane was matched after normalisation")
        finally:
            fx.close()
    finally:
        shutil.rmtree(base, ignore_errors=True)


@test("NO-PREDECESSOR")
def t_no_predecessor(module):
    """No lane record at all: nothing to collide with, dispatch is allowed."""
    wt = os.path.join(tempfile.gettempdir(), "succ-nopred-wt")
    fx = Fixture(worktree=wt, lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd="/elsewhere"))],
                 cmux_rows=[])
    try:
        rc, out = run_preflight(fx, module=module)
        assert_eq(rc, 0, "rc 0 = a fresh unit is dispatchable")
        assert_in("no lane record for this worktree", out, "the absence is stated, not implied")
    finally:
        fx.close()


@test("PROCESS-UNREADABLE")
def t_process_unreadable(module):
    """An unreadable process read is UNKNOWN, never GONE (fail closed)."""
    wt = os.path.join(tempfile.gettempdir(), "succ-procunread-wt")
    fx = Fixture(worktree=wt, lanes=[], cmux_rows=[])
    try:
        rc, out = run_preflight(fx, "--pgrep-bin", os.path.join(fx.dir, "missing-pgrep"),
                                module=module)
        assert_eq(rc, 4, "rc 4 = could not verify, do not dispatch")
        assert_in("verdict: UNKNOWN", out, "verdict is UNKNOWN")
        assert_in("process-read-unreadable", out, "the unreadable read is named")
    finally:
        fx.close()


@test("STORE-UNREADABLE")
def t_store_unreadable(module):
    """An unreadable lane store is UNKNOWN, never GONE (fail closed)."""
    wt = os.path.join(tempfile.gettempdir(), "succ-storeunread-wt")
    fx = Fixture(worktree=wt, lanes=[], cmux_rows=[])
    try:
        rc, out = run_preflight(fx, "--store", os.path.join(fx.dir, "no-store.json"),
                                module=module)
        assert_eq(rc, 4, "rc 4 = no verdict may rest on an unread store")
        assert_in("verdict: UNKNOWN", out, "verdict is UNKNOWN")
        assert_in("store-unreadable", out, "the unreadable store is named")
    finally:
        fx.close()


@test("CMUX-UNREAD")
def t_cmux_unread(module):
    """An unreadable cmux never decides: the authoritative reads still do."""
    wt = os.path.join(tempfile.gettempdir(), "succ-cmuxunread-wt")
    fx = Fixture(worktree=wt,
                 lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 cmux_rows=None, cmux_readable=False)
    try:
        rc, out = run_preflight(fx, module=module)
        assert_eq(rc, 0, "rc 0 = GONE was proven without cmux (the gate can still open)")
        assert_in("cmux: unread", out, "the unread corroborating read is stated")
        # And it must not be read as liveness either: the same unreadable cmux on
        # a LIVE lane still reads LIVE, from the predicate alone.
        fx2 = Fixture(worktree=wt,
                      lanes=[(SID, WS, record(SID, WS, PID_LIVE, cwd=wt))],
                      ps_rows=[ps_row(PID_LIVE)],
                      cmux_rows=None, cmux_readable=False)
        try:
            rc2, out2 = run_preflight(fx2, module=module)
            assert_eq(rc2, 3, "rc 3 = a live lane still blocks with cmux unreadable")
        finally:
            fx2.close()
    finally:
        fx.close()


@test("EMIT")
def t_emit(module):
    """--emit appends the proof to the dispatch file; the exit code is unchanged."""
    wt = os.path.join(tempfile.gettempdir(), "succ-emit-wt")
    fx = Fixture(worktree=wt,
                 lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 cmux_rows=[])
    brief = os.path.join(fx.dir, "prompt-3834.txt")
    with open(brief, "w", encoding="utf-8") as fh:
        fh.write("Autonomous engineering lane. Your unit: land PR #4412.\n")
    try:
        rc, _ = run_preflight(fx, "--emit", brief, module=module)
        rc2, _ = run_preflight(fx, "--emit", brief, module=module)
        with open(brief, "r", encoding="utf-8") as fh:
            text = fh.read()
        assert_eq(rc, 0, "rc from the emitting run is unchanged")
        assert_eq(rc2, 0, "rc from the second emitting run is unchanged")
        assert_eq(text.count("--- successor-preflight (#1317) ---"), 2,
                  "the proof is APPENDED, never rewritten")
        assert_in("verdict: PREDECESSOR-GONE", text, "the dispatch file carries the verdict")
        assert_in("Autonomous engineering lane", text, "the existing brief survives the emit")
    finally:
        fx.close()


@test("JSON")
def t_json(module):
    """--json emits the same verdict, machine-readable."""
    wt = os.path.join(tempfile.gettempdir(), "succ-json-wt")
    fx = Fixture(worktree=wt,
                 lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 cmux_rows=[])
    try:
        rc, out = run_preflight(fx, "--json", module=module)
        assert_eq(rc, 0, "rc 0")
        doc = json.loads(out)
        assert_eq(doc["verdict"], "PREDECESSOR-GONE", "JSON verdict matches the block verdict")
        assert_eq(doc["process_readable"], True, "the process read is reported readable")
        assert_eq(doc["lanes"][0]["state"], "dead", "the lane verdict is in the payload")
    finally:
        fx.close()


@test("PROC-FALLBACK")
def t_proc_fallback(module):
    """The /proc fallback (no lsof) must be EXERCISED, not assumed.

    Until this leg every fixture answered through the lsof shim, so `_proc_cwds`
    was never reached by a test — and it is the only reader when lsof is absent,
    i.e. the whole fail-closed contract rests on code no leg ran.
    """
    wt = os.path.join(tempfile.gettempdir(), "succ-procfb-wt")
    fx = Fixture(worktree=wt, lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 pids=[PID_OTHER], cmux_rows=[])
    fx.proc_cwd(PID_OTHER, wt)
    try:
        rc, out = run_preflight(fx, "--lsof-bin", os.path.join(fx.dir, "no-lsof"),
                                module=module)
        assert_eq(rc, 3, "rc 3 = the /proc fallback found the live pi")
        assert_in("live-pi-cwd:%d" % PID_OTHER, out, "the /proc-read cwd is the witness")
    finally:
        fx.close()


@test("PROC-READ-REFUSED")
def t_proc_refused(module):
    """A REFUSED cwd read is UNKNOWN, never GONE.

    The P1 both cycle-1 reviewers reproduced: `except OSError: continue` scored
    `EACCES`/`EPERM` (another uid, `hidepid`) and `EINVAL` (non-symlink) as "the
    pid is not here", so a live predecessor whose cwd could not be read was
    reported GONE while the read claimed to be complete.
    """
    wt = os.path.join(tempfile.gettempdir(), "succ-procref-wt")
    fx = Fixture(worktree=wt, lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 pids=[PID_OTHER], cmux_rows=[])
    fx.proc_cwd(PID_OTHER, wt, kind="file")   # readlink -> EINVAL: refused
    try:
        rc, out = run_preflight(fx, "--lsof-bin", os.path.join(fx.dir, "no-lsof"),
                                module=module)
        assert_eq(rc, 4, "rc 4 = a refused read is not evidence of absence")
        assert_in("verdict: UNKNOWN", out, "verdict is UNKNOWN")
        assert_in("process-read-unreadable", out, "the refused read is named")
    finally:
        fx.close()


@test("PARTIAL-CWD-READ")
def t_partial_cwd(module):
    """A partial cwd read must abstain, and an `ENOENT` pid is an ANSWER.

    lsof exits 1 and OMITS a pid it could not stat. The old `if m: return m,
    True` accepted that partial map as the complete reading, so a live pi it
    could not stat read as "not in this worktree" -> GONE.
    """
    wt = os.path.join(tempfile.gettempdir(), "succ-partial-wt")
    other = os.path.join(tempfile.gettempdir(), "succ-partial-other")
    lanes = [(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))]
    # Case 1 — the omitted pid's cwd is REFUSED by /proc: the read is unusable.
    fx = Fixture(worktree=wt, lanes=lanes, pids=[PID_LIVE, PID_OTHER],
                 cwd_map={PID_OTHER: other}, cmux_rows=[])
    fx.proc_cwd(PID_LIVE, wt, kind="file")
    try:
        rc, out = run_preflight(fx, module=module)
        assert_eq(rc, 4, "rc 4 = a partial read that cannot be completed abstains")
        assert_in("verdict: UNKNOWN", out, "verdict is UNKNOWN")
    finally:
        fx.close()
    # Case 2 — the omitted pid is provably GONE (/proc has no entry for it): that
    # IS an answer, so the merged read completes and GONE is still provable.
    fx2 = Fixture(worktree=wt, lanes=lanes, pids=[PID_LIVE, PID_OTHER],
                  cwd_map={PID_OTHER: other}, cmux_rows=[])
    try:
        rc, out = run_preflight(fx2, module=module)
        assert_eq(rc, 0, "rc 0 = the omitted pid is gone, so the read is complete")
        assert_in("no live pi rooted in this worktree", out, "the absence is stated")
    finally:
        fx2.close()


@test("DELETED-CWD")
def t_deleted_cwd(module):
    """A cwd the kernel spells `/path (deleted)` is the SAME worktree.

    `/proc/<pid>/cwd` appends ` (deleted)` once the directory is unlinked, so a
    worktree removed under a running lane normalised to a different string and
    its live predecessor read as GONE.
    """
    wt = os.path.join(tempfile.gettempdir(), "succ-deleted-wt")
    fx = Fixture(worktree=wt, lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 pids=[PID_OTHER], cwd_map={PID_OTHER: wt + " (deleted)"},
                 cmux_rows=[])
    try:
        rc, out = run_preflight(fx, module=module)
        assert_eq(rc, 3, "rc 3 = the unlinked spelling still names this worktree")
        assert_in("live-pi-cwd:%d" % PID_OTHER, out, "the live pid is the witness")
    finally:
        fx.close()


@test("NO-WORKTREE")
def t_no_worktree(module):
    """A --worktree that is not a readable directory is exit 2, never GONE.

    "There is no directory here" and "I proved no predecessor holds it" are
    different facts, and a dispatcher switching on the documented exit code must
    be able to tell them apart. The docstring promised exit 2 for an unreadable
    working directory while the code returned a GONE proof.
    """
    wt = os.path.join(tempfile.gettempdir(), "succ-nodir-wt")
    fx = Fixture(worktree=wt, lanes=[], cmux_rows=[])
    ghost = os.path.join(fx.dir, "does-not-exist", "nope")
    try:
        rc, out = run_preflight(fx, "--worktree", ghost, module=module)
        assert_eq(rc, 2, "rc 2 = nothing was decided")
        assert_in("not a readable directory", out, "the environment error is named")
        assert_not_in("PREDECESSOR-GONE", out, "a missing target is never a GONE proof")
    finally:
        fx.close()


@test("EMIT-FAIL")
def t_emit_fail(module):
    """A failed --emit is exit 2 — the proof could not be attached."""
    wt = os.path.join(tempfile.gettempdir(), "succ-emitfail-wt")
    fx = Fixture(worktree=wt, lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 cmux_rows=[])
    try:
        rc, out = run_preflight(fx, "--emit", fx.dir, module=module)
        assert_eq(rc, 2, "rc 2 = the proof could not be written")
        assert_in("cannot emit to", out, "the emit failure is named")
    finally:
        fx.close()


@test("CMUX-EPOCHS")
def t_cmux_epochs(module):
    """An ISO-8601 stamp and an epoch-MILLIS stamp are both read as recency.

    Every other fixture uses epoch seconds, so the `_epoch` string and the
    millis branch were never reached — and real cmux data is where an ISO or
    millis stamp would come from.
    """
    wt = os.path.join(tempfile.gettempdir(), "succ-epochs-wt")
    iso = _dt.datetime.fromtimestamp(NOW_S - 60, _dt.timezone.utc) \
        .strftime("%Y-%m-%dT%H:%M:%SZ")
    fx = Fixture(worktree=wt, lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 cmux_rows=[{"id": WS, "current_directory": wt,
                             "latest_submitted_at": iso},
                            {"id": WS2, "current_directory": wt,
                             "updated_at": (NOW_S - 30) * 1000}])
    try:
        rc, out = run_preflight(fx, module=module)
        assert_eq(rc, 3, "rc 3 = recent inbound activity blocks the successor")
        assert_in("recent-cmux-inbound:11111111,22222222", out,
                  "both the ISO row and the millis row are recent")
    finally:
        fx.close()


@test("CMUX-UPDATED-ONLY")
def t_cmux_updated_only(module):
    """The workspace record's own `updated_at` alone is enough to block."""
    wt = os.path.join(tempfile.gettempdir(), "succ-updonly-wt")
    fx = Fixture(worktree=wt, lanes=[(SID, WS, record(SID, WS, PID_DEAD, cwd=wt))],
                 cmux_rows=[{"id": WS, "current_directory": wt,
                             "updated_at": NOW_S - 30}])
    try:
        rc, out = run_preflight(fx, module=module)
        assert_eq(rc, 3, "rc 3 = a recently written workspace record blocks")
        assert_in("recent-cmux-inbound:11111111", out, "the row is the witness")
    finally:
        fx.close()


# ── red control ──────────────────────────────────────────────────────────
MUTATIONS = [
    ("drop the live-process check", "LIVE-PROCESS",
     "    if process_pids:\n        why.append(\"live-pi-cwd:\" + \",\".join(str(p) for p in process_pids))\n        return LIVE, why\n",
     "    pass\n"),
    ("drop the live-lane check", "LIVE-LANE",
     "    live_lanes = [l for l in lanes if l[\"state\"] != \"dead\"]\n",
     "    live_lanes = []\n"),
    ("drop the recent-cmux check", "LIVE-CMUX",
     "    recent = [a for a in cmux_activity if a.get(\"recent\")]\n",
     "    recent = []\n"),
    ("unreadable store becomes GONE", "STORE-UNREADABLE",
     "    if not store_readable:\n        return UNKNOWN, [\"store-unreadable\"]\n",
     "    pass\n"),
    ("unreadable process read becomes GONE", "PROCESS-UNREADABLE",
     "    if not process_readable:\n        # The worktree read could not be taken; lanes alone cannot prove absence\n        # of a process whose record the store never had.\n        return UNKNOWN, [\"process-read-unreadable\"]\n",
     "    pass\n"),
    ("drop the realpath normalisation", "REALPATH",
     "        return os.path.realpath(os.path.normpath(s))\n",
     "        return s\n"),
    ("ignore the cmux recency window", "CMUX-WINDOW",
     "            \"recent\": bool(newest is not None and (now_s - newest) <= recent_s),\n",
     "            \"recent\": bool(newest is not None),\n"),
    ("match cmux rows without their cwd", "OTHER-WORKTREE",
     "        if not isinstance(cwd, str) or _real(cwd) != target:\n            continue\n",
     "        if not isinstance(cwd, str):\n            continue\n"),
    ("call every lane dead (drop the shared predicate)", "LIVE-LANE",
     "            \"state\": verdict.state,\n",
     "            \"state\": \"dead\",\n"),
    ("accept a partial cwd read as complete", "PARTIAL-CWD-READ",
     "        if m:\n            if set(m) == set(pids):\n                return m, True\n",
     "        if m:\n            if True:\n                return m, True\n"),
    ("an unreadable cwd read becomes an omitted one", "PROC-READ-REFUSED",
     "        except FileNotFoundError:\n            continue          # proven gone — an answer, not a gap in the read\n        except OSError:\n            return {}, False  # refused — never evidence of absence\n",
     "        except OSError:\n            continue\n"),
    ("drop the unlinked-cwd normalisation", "DELETED-CWD",
     "    if cwd.endswith(DELETED_SUFFIX):\n        return _real(cwd[: -len(DELETED_SUFFIX)]) == target\n",
     "    if False:\n        return _real(cwd[: -len(DELETED_SUFFIX)]) == target\n"),
    ("report a nonexistent worktree as GONE", "NO-WORKTREE",
     "    if not os.path.isdir(target):\n",
     "    if False:\n"),
    ("accept a non-procfs root as the process table", "ROOT-NOT-PROCFS",
     "    if not _is_procfs(proc_root):\n        return {}, False\n",
     "    if not os.path.isdir(proc_root):\n        return {}, False\n"),
    ("read an epoch-millis stamp as epoch seconds", "CMUX-WINDOW",
     "        return v / 1000.0 if v > 1e11 else v\n",
     "        return v\n"),
]


def run_test(name, fn, module=None):
    global PASS, FAIL
    before = FAIL
    print("\n[%s]%s" % (name, "" if module is None else "  (mutation: %s)" % module))
    fn(module)
    return FAIL > before


def red_control():
    """Every mutation must turn its paired test RED."""
    print("=" * 72)
    print("RED CONTROL — each mutation is applied to a TEMP copy and re-tested")
    print("=" * 72)
    src = open(MODULE_PATH, "r", encoding="utf-8").read()
    failures = 0
    for desc, leg, old, new in MUTATIONS:
        if old not in src:
            print("\n❌ MUTATION TARGET NOT FOUND: %s" % desc)
            failures += 1
            continue
        tmpd = tempfile.mkdtemp(prefix="succ-mut-")
        mod = os.path.join(tmpd, "successor_preflight.py")
        with open(mod, "w", encoding="utf-8") as fh:
            fh.write(src.replace(old, new, 1))
        # The mutated module imports its SIBLINGS by directory; without them the
        # mutated run would die on the import (rc=2) and the "caught it" verdict
        # would be vacuous — a mutation that never reaches the code under test.
        for sibling in ("liveness.py", "lane_liveness.py"):
            shutil.copyfile(os.path.join(HERE, sibling), os.path.join(tmpd, sibling))
        try:
            fn = dict(TESTS)[leg]
            went_red = run_test(desc, fn, module=mod)
            if went_red:
                print("  ✅ %s -> %s caught it" % (desc, leg))
            else:
                print("  ❌ %s -> %s did NOT catch it (a test that cannot fail pins nothing)" % (desc, leg))
                failures += 1
        finally:
            shutil.rmtree(tmpd, ignore_errors=True)
    return failures


def main(argv):
    if "--red-control" in argv:
        # In this mode the FAIL counter counts the EXPECTED red legs of the paired
        # tests, so the exit code must rest on MISSED mutations only — otherwise a
        # suite that caught every mutation would still exit 1 and redden CI.
        missed = red_control()
        print("\n%s\nred-control missed=%d PASS=%d FAIL=%d (FAIL here are the expected red legs)"
              % ("=" * 72, missed, PASS, FAIL))
        return 1 if missed else 0
    failures = 0
    for name, fn in TESTS:
        if run_test(name, fn):
            failures += 1
    print("\n%s\nPASS=%d FAIL=%d" % ("=" * 72, PASS, FAIL))
    return 1 if (failures or FAIL) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
