#!/usr/bin/env python3
"""scripts/orphan_reap.test.py — the offline acceptance + MUTATION suite for orphan-reap.py.

WHY THIS FILE EXISTS
`scripts/orphan-reap.py` carries the three gates #1244 says must live in code rather than in prose
("the path that actually reached pids 10589/10607 has no code gate" — an agent applying a *prose*
rule found a human's `Terminal.app → login -pf → -zsh → node → codex` chain and called it parked).
A gate that only exists as prose cannot be tested; a gate whose suite lives outside CI is inert by
never running. So: no live processes, no clock, no `ps` of the box — every case is a synthetic
process table driven through the REAL script via the PS_BIN/KILL_BIN/LAUNCHCTL_BIN/LSOF_BIN seams
(the vocabulary `scripts/pi-reap-idle.sh` already uses), and every gate is proven by MUTATION:
`--mutations` reintroduces the defect each test exists to catch, into a TEMP copy of the script, and
requires the paired test to go RED. A mutation whose test still passes is reported as a suite
failure — a test that cannot catch its own defect is decoration.

    python3 scripts/orphan_reap.test.py               # the acceptance tests
    python3 scripts/orphan_reap.test.py --mutations    # each mutation, RED
    ORPHAN_REAP_UNDER_TEST=/path/to/orphan-reap.py python3 scripts/orphan_reap.test.py

THE CASES THAT MATTER (in the order the task states them)
  * T1  parked under a `Terminal`/`login`/shell ancestor ⇒ NEVER reaped, on a DESTRUCTIVE run
        (the 2026-09-17 near-miss: pids 10589/10607, 0.00 s and 0.02 s of CPU over 25 s).
  * T2  daemonised `ppid 1`, no human ancestor, parked, past its distribution ⇒ selected by
        `--apply` and NOT by the dry run.
  * T3  an ancestry read that cannot reach the top ⇒ a REPORT naming the gate and the observation,
        never a kill.
  * T4  the window/tolerance the code DECIDES with are the ones the report PRINTS (boundary 0.09 s
        vs 0.11 s), and a sub-floor window is refused unless signalling is redirected.
  * T5-T8 the class distribution is data (a 40 m merge rail is normal; an 11h30m shard is 26.5×),
        a designed daemon / a diagnostic-bearing candidate / an unreadable `launchctl` are all
        REPORTED, the dry run is the default, and every decision is logged with its evidence.

Exit: 0 = every test passed (and, with --mutations, every mutation was caught), 1 = otherwise.
"""
from __future__ import annotations

import atexit
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# The script under test. A mutation run (or an operator) may point this elsewhere; every CLI
# invocation AND the importlib read of the constants follow it, so a mutation cannot be caught by
# one half of the suite while the other half still exercises the shipped file.
SCRIPT = os.environ.get("ORPHAN_REAP_UNDER_TEST") or os.path.normpath(
    os.path.join(HERE, "orphan-reap.py"))
# A checkout under the CALLER's home — the population this reaper is scoped to (it refuses any
# other account's checkouts, and refuses to run as root at all). It is a SENTINEL: each bed rewrites
# it to a path under that bed's fake HOME, because the script derives the population from `$HOME`
# and a fixture that hardcoded the REAL home would silently fall outside it (that is exactly how the
# first run of this suite went red when the population was tightened).
OWNER = "/OWNER_HOME/GitHub/tortoise"

# ── the synthetic process table ───────────────────────────────────────────────────────────────
# One row per line, exactly the `ps -Ao pid=,ppid=,uid=,tty=,pcpu=,time=,etime=,comm=,args=`
# shape the script reads (TEN fields, `tty` included). The uid column carries the RUNNING uid (see
# _uid()), not a literal: the interactive-shell arm compares against os.getuid(), so a hardcoded
# value would make that arm untestable on any box whose uid differs.
# uid 501 is the fixture's uid on every box that runs this (we compare against os.getuid(), so the
# fixtures are written with the RUNNING uid — see _uid()).


def _uid() -> str:
    return str(os.getuid())


def row(pid, ppid, comm, args, *, cpu="00:00.00", etime="11:30:00", uid=None, pcpu="0.0", tty="??"):
    return f"{pid} {ppid} {uid or _uid()} {tty} {pcpu} {cpu} {etime} {comm} {args}"


def pytest_row(pid, ppid, *, cpu="00:00.00", etime="11:30:00", args=None):
    argv = args or f"{OWNER}/.venv/bin/python -m pytest tests/ -q"
    return row(pid, ppid, "/usr/bin/python3.12", argv, cpu=cpu, etime=etime)


LAUNCHD = row(1, 0, "/sbin/launchd", "/sbin/launchd")


# ── the hermetic harness ─────────────────────────────────────────────────────────────────────
PS_SHIM = """#!/usr/bin/env bash
n_file="${FAKE_PS_COUNT:?}"
n=$(cat "$n_file" 2>/dev/null || echo 0)
n=$((n+1)); echo "$n" > "$n_file"
case "$n" in
  1) cat "${FAKE_PS_BEFORE:?}" ;;
  2) cat "${FAKE_PS_AFTER:?}" ;;
  3) if [ -n "${FAKE_PS_PREKILL:-}" ]; then cat "$FAKE_PS_PREKILL"; else cat "${FAKE_PS_AFTER:?}"; fi ;;
  *) if [ -n "${FAKE_PS_POST:-}" ]; then cat "$FAKE_PS_POST"; else cat "${FAKE_PS_AFTER:?}"; fi ;;
esac
"""
KILL_SHIM = """#!/usr/bin/env bash
[ -n "${FAKE_KILL_LOG:?}" ] || exit 0
echo "$*" >> "$FAKE_KILL_LOG"
exit 0
"""
LSOF_SHIM = """#!/usr/bin/env bash
# lsof -p <pid> -> the fixture for that pid, or exit 1 (lsof's "nothing found for this pid")
pid="$2"
f="${FAKE_LSOF_DIR:-}/$pid.txt"
if [ -n "${FAKE_LSOF_DIR:-}" ] && [ -f "$f" ]; then cat "$f"; exit 0; fi
exit 1
"""
LAUNCHCTL_SHIM = """#!/usr/bin/env bash
# The reaper asks for the caller's GUI domain FIRST, by name; the bare read is the fallback.
# FAKE_LAUNCHCTL_MODE=fail         -> every domain read fails
# FAKE_LAUNCHCTL_MODE=no-gui       -> only the bare `launchctl list` answers
if [ "${FAKE_LAUNCHCTL_MODE:-ok}" = fail ]; then echo "launchctl: boom" >&2; exit 1; fi
if [ "${FAKE_LAUNCHCTL_MODE:-ok}" = no-gui ] && [ "${2:-}" != "" ]; then exit 1; fi
if [ "${FAKE_LAUNCHCTL_MODE:-ok}" = by-domain ]; then
    if [ "${2:-}" != "" ]; then cat "${FAKE_LAUNCHCTL_GUI:?}"; else cat "${FAKE_LAUNCHCTL_BARE:?}"; fi
    exit 0
fi
cat "${FAKE_LAUNCHCTL:?}"
"""


class Bed:
    """One hermetic bed: fake binaries, a fake HOME, fixture files, and a place to log kills."""

    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="orphan-reap-test-")
        # This PR is about not leaking processes and scratch; a suite that leaves a bed behind per
        # test would be the same defect in miniature. Removed at exit, never mid-test.
        atexit.register(lambda p=self.tmp: shutil.rmtree(p, ignore_errors=True))
        self.bin = os.path.join(self.tmp, "bin")
        self.home = os.path.join(self.tmp, "home")
        self.state = os.path.join(self.tmp, "state")
        self.lsof = os.path.join(self.tmp, "lsof")
        for d in (self.bin, self.home, self.state, self.lsof,
                  os.path.join(self.home, ".pi", "agent", "state")):
            os.makedirs(d, exist_ok=True)
        self._write(os.path.join(self.bin, "ps"), PS_SHIM)
        self._write(os.path.join(self.bin, "kill"), KILL_SHIM)
        self._write(os.path.join(self.bin, "lsof"), LSOF_SHIM)
        self._write(os.path.join(self.bin, "launchctl"), LAUNCHCTL_SHIM)
        self.kill_log = os.path.join(self.tmp, "kill.log")
        self.count = os.path.join(self.tmp, "ps.count")
        self.env = {
            "HOME": self.home,
            "PS_BIN": os.path.join(self.bin, "ps"),
            "KILL_BIN": os.path.join(self.bin, "kill"),
            "LSOF_BIN": os.path.join(self.bin, "lsof"),
            "LAUNCHCTL_BIN": os.path.join(self.bin, "launchctl"),
            "ORPHAN_REAP_STATE_DIR": self.state,
            "FAKE_PS_COUNT": self.count,
            "FAKE_KILL_LOG": self.kill_log,
            "FAKE_LSOF_DIR": self.lsof,
            # A READABLE domain must carry at least one pid row, or gate 4 correctly reads it as
            # INCONCLUSIVE (an empty parse is ambiguous — ssh/cron see only the background domain).
            # pid 999 is a decoy: registered, but not a candidate.
            "FAKE_LAUNCHCTL": self._fixture("launchctl",
                                            "PID\tStatus\tLabel\n999\t0\tcom.example.decoy\n"),
        }

    # fixtures -------------------------------------------------------------------------------
    def _write(self, path, text):
        with open(path, "w") as fh:
            fh.write(text)
        os.chmod(path, 0o755)

    def _fixture(self, name, text):
        path = os.path.join(self.tmp, f"{name}.fixture")
        with open(path, "w") as fh:
            fh.write(text)
        return path

    def table(self, before, after=None, prekill=None, post=None):
        """The four reads: sample 1, sample 2, pre-SIGNAL re-verify, post-SIGTERM survivor check."""
        owner = os.path.join(self.home, "GitHub", "tortoise")
        before = [ln.replace(OWNER, owner) for ln in before]
        after = [ln.replace(OWNER, owner) for ln in (after or before)]
        self.env["FAKE_PS_BEFORE"] = self._fixture("before", "\n".join(before) + "\n")
        self.env["FAKE_PS_AFTER"] = self._fixture("after", "\n".join(after) + "\n")
        if prekill is not None:
            self.env["FAKE_PS_PREKILL"] = self._fixture(
                "prekill", "\n".join(ln.replace(OWNER, owner) for ln in prekill) + "\n")
        if post is not None:
            self.env["FAKE_PS_POST"] = self._fixture(
                "post", "\n".join(ln.replace(OWNER, owner) for ln in post) + "\n")

    def lsof_for(self, pid, lines):
        with open(os.path.join(self.lsof, f"{pid}.txt"), "w") as fh:
            fh.write("COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n" + "\n".join(lines) + "\n")

    def env_over(self, **extra):
        e = dict(os.environ)
        e.update(self.env)
        e.update({k: str(v) for k, v in extra.items()})
        return e

    # running ---------------------------------------------------------------------------------
    def run(self, *args, window="1", env=None):
        """Drive the REAL script. `window=1` is only legal because KILL_BIN is redirected."""
        argv = [sys.executable, SCRIPT]
        if window is not None:
            argv += ["--sample", window]
        argv += list(args)
        r = subprocess.run(argv, capture_output=True, text=True,
                           env=env or self.env_over(), timeout=120)
        return r

    def kills(self):
        try:
            with open(self.kill_log) as fh:
                return [ln.strip() for ln in fh if ln.strip()]
        except FileNotFoundError:
            return []

    def log_lines(self):
        path = os.path.join(self.state, "orphan-reap-decisions.jsonl")
        if not os.path.exists(path):
            return []
        import json
        with open(path) as fh:
            return [json.loads(ln) for ln in fh if ln.strip()]


def assert_in(haystack, needle, what):
    if needle not in haystack:
        raise AssertionError(f"{what}: expected {needle!r} in output:\n{haystack}")


def assert_not_in(haystack, needle, what):
    if needle in haystack:
        raise AssertionError(f"{what}: {needle!r} MUST NOT appear in output:\n{haystack}")


def assert_eq(got, want, what):
    if got != want:
        raise AssertionError(f"{what}: expected {want!r}, got {got!r}")


# ── T1: the 2026-09-17 near-miss — a human's chain is NEVER reaped ───────────────────────────
def t1_human_ancestor_never_reaped():
    b = Bed()
    # Terminal.app -> login -pf -> -zsh -> python/pytest, all parked, 12h old, past distribution.
    table = [
        pytest_row(5000, 5001, etime="12:00:00"),
        row(5001, 5002, "-zsh", "-zsh", tty="ttys003"),
        row(5002, 5003, "login", "login -pf danielospina", tty="ttys003"),
        row(5003, 1, "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
            "Terminal.app/Contents/MacOS/Terminal"),
        LAUNCHD,
    ]
    b.table(table)
    r = b.run("--apply")
    assert_eq(r.returncode, 0, "T1 exit code")
    assert_eq(b.kills(), [], "T1 a human-ancestor candidate must never be signalled")
    assert_in(r.stdout, "HUMAN:", "T1 the ancestry gate must NAME the human ancestor")
    assert_in(" ".join(b.log_lines()[0]["ancestry_path"]), "5001:-zsh",
              "T1 the logged chain records the shell it stopped at")
    assert_in(r.stdout, "=> REPORT", "T1 verdict is REPORT")
    assert_in(r.stdout, "gate 2", "T1 the reason names gate 2")
    # the log carries the same evidence
    (rec,) = b.log_lines()
    assert_eq(rec["verdict"], "REPORT", "T1 logged verdict")
    assert_in(rec["ancestry"], "HUMAN:", "T1 logged ancestry verdict")
    assert_in(" ".join(rec["ancestry_path"]), "5000:", "T1 the walked chain is logged")


def t1a_interactive_shell_ancestor_never_reaped():
    """The SHELL arm of gate 2, in isolation: `-zsh` is a login shell owned by the caller's uid."""
    b = Bed()
    b.table([pytest_row(5050, 5051, etime="12:00:00"),
             row(5051, 1, "-zsh", "-zsh", tty="ttys001"),
             LAUNCHD])
    r = b.run("--apply")
    assert_eq(b.kills(), [], "T1a an interactive-shell ancestor must never be signalled")
    assert_in(r.stdout, "HUMAN:shell:-zsh", "T1a the shell arm is named")


def t1c_login_marker_directly():
    """`login(1)` itself: comm="login", args="login -pf <user>" — no path in either."""
    b = Bed()
    b.table([pytest_row(5200, 5201, etime="12:00:00"),
             row(5201, 1, "login", "login -pf danielospina"),
             LAUNCHD])
    r = b.run("--apply")
    assert_eq(b.kills(), [], "T1c a login(1)-rooted candidate must never be signalled")
    assert_in(r.stdout, "HUMAN:login", "T1c the login marker is named")


def t1e_own_tty_is_inconclusive():
    """A human's process disowned by a crashed terminal: ppid 1, no ancestor left, but it owns the tty."""
    b = Bed()
    b.table([pytest_row(5400, 1, etime="12:00:00", args=f"{OWNER}/.venv/bin/python -m pytest tests/ -q")
             .replace(" 0.0 ", " 0.0 ", 1), LAUNCHD])
    # rewrite the row with a real tty (the helper defaults to none)
    b.table([row(5400, 1, "/usr/bin/python3.12",
                 f"{OWNER}/.venv/bin/python -m pytest tests/ -q", etime="12:00:00", tty="ttys004"),
             LAUNCHD])
    r = b.run("--apply")
    assert_eq(b.kills(), [], "T1e a candidate that owns a tty must never be signalled")
    assert_in(r.stdout, "owns a tty (ttys004)", "T1e the tty is named")
    assert_in(r.stdout, "gate 2: INCONCLUSIVE", "T1e gate 2 refuses without an ancestor to walk")


def t1d_own_argv_is_not_an_ancestor():
    """`pytest tests/test_login.py` must not read as `HUMAN:login` (review cycle 2, P3)."""
    b = Bed()
    b.table([pytest_row(5300, 1, etime="12:00:00",
                        args=f"{OWNER}/.venv/bin/python -m pytest tests/test_login.py -q"),
             LAUNCHD])
    r = b.run()
    assert_in(r.stdout, "gate 2_ancestry    NO-HUMAN",
              "T1d the candidate's own argv is not an ancestor")
    assert_in(r.stdout, "=> REAP", "T1d the shard is not refused by its own filename")


def t1b_terminal_marker_directly():
    """The marker itself, with no shell in between — Terminal.app is the FIRST host in the chain."""
    b = Bed()
    b.table([
        pytest_row(5100, 5103, etime="12:00:00"),
        row(5103, 1, "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
            "Terminal.app/Contents/MacOS/Terminal"),
        LAUNCHD,
    ])
    r = b.run("--apply")
    assert_eq(b.kills(), [], "T1b a Terminal-rooted candidate must never be signalled")
    assert_in(r.stdout, "HUMAN:Terminal", "T1b the marker is named")


# ── T2: a daemonised ppid-1 orphan IS selected — by --apply, never by the dry run ────────────
def t2_daemonised_ppid1_selected_only_on_apply():
    b = Bed()
    before = [pytest_row(6000, 1, etime="11:30:00"), LAUNCHD]
    b.table(before, post=[LAUNCHD])          # after the signals, the pid is gone
    dry = b.run()
    assert_eq(dry.returncode, 0, "T2 dry-run exit")
    assert_eq(b.kills(), [], "T2 the DRY RUN must signal nothing")
    assert_in(dry.stdout, "=> REAP", "T2 the dry run still SHOWS what it would reap")
    assert_in(dry.stdout, "dry run", "T2 the dry run says so")

    open(b.count, "w").write("0")   # the dry run consumed samples 1-2
    ap = b.run("--apply")
    assert_eq(ap.returncode, 0, "T2 apply exit")
    assert_eq(b.kills(), ["-15 6000"], "T2 apply signals exactly the selected pid with SIGTERM")
    assert_in(ap.stdout, "verified gone: 6000", "T2 the death is verified, not assumed")
    assert_eq(b.log_lines()[-1]["verdict"], "REAP", "T2 the reap is logged as REAP")


def t2b_reused_pid_is_suppressed():
    """Between the decision and the signal the pid is reused by an UNRELATED process."""
    b = Bed()
    b.table([pytest_row(6100, 1, etime="11:30:00"), LAUNCHD],
            # the pre-signal read shows a lane worker now holding that pid
            prekill=[row(6100, 1, "/usr/bin/python3.12",
                         f"{OWNER}/.venv/bin/python -m pytest tests/test_live_lane.py",
                         etime="00:00:20"), LAUNCHD],
            post=[row(6100, 1, "/usr/bin/python3.12",
                      f"{OWNER}/.venv/bin/python -m pytest tests/test_live_lane.py",
                      etime="00:00:25"), LAUNCHD])
    r = b.run("--apply")
    assert_eq(r.returncode, 0, "T2b exit")
    assert_eq(b.kills(), [], "T2b a REUSED pid must never be signalled")
    assert_in(r.stdout, "SUPPRESS 6100", "T2b the suppression is reported")
    assert_in(r.stdout, "pid REUSED", "T2b the reason names the reuse")
    assert_eq(b.log_lines()[-1]["verdict"], "SUPPRESSED", "T2b the suppression is logged")


def t2c_reused_pid_with_identical_argv():
    """Identical comm+argv but a YOUNGER process: only the elapsed-time arm can catch this."""
    b = Bed()
    b.table([pytest_row(6200, 1, etime="11:30:00"), LAUNCHD],
            prekill=[pytest_row(6200, 1, etime="00:10:00"), LAUNCHD],
            post=[pytest_row(6200, 1, etime="00:10:05"), LAUNCHD])
    r = b.run("--apply")
    assert_eq(b.kills(), [], "T2c an identical-argv pid reuse must not be signalled")
    assert_in(r.stdout, "elapsed time went backwards", "T2c the etime arm names itself")
    assert_eq(b.log_lines()[-1]["verdict"], "SUPPRESSED", "T2c logged as SUPPRESSED")


def t2d_sigkill_arm_is_identity_checked():
    """SIGTERM survivor whose pid is REUSED inside the grace window must not be SIGKILLed."""
    b = Bed()
    b.table([pytest_row(6400, 1, etime="11:30:00"), LAUNCHD],
            post=[row(6400, 1, "/usr/bin/python3.12",
                      f"{OWNER}/.venv/bin/python -m pytest tests/test_other.py",
                      etime="00:00:05"), LAUNCHD])
    r = b.run("--apply")
    assert_eq(b.kills(), ["-15 6400"], "T2d SIGTERM only — the SIGKILL is suppressed")
    assert_in(r.stdout, "SUPPRESS SIGKILL 6400", "T2d the SIGKILL suppression is reported")


def t2e_genuine_survivor_gets_sigkill():
    """The SIGKILL arm is not inert: the SAME process surviving TERM is escalated."""
    b = Bed()
    b.table([pytest_row(6500, 1, etime="11:30:00"), LAUNCHD],
            post=[pytest_row(6500, 1, etime="11:30:04"), LAUNCHD])
    r = b.run("--apply")
    assert_eq(b.kills(), ["-15 6500", "-9 6500"], "T2e a genuine survivor is escalated to SIGKILL")
    assert_in(r.stdout, "SIGKILL -> 6500", "T2e the escalation is reported")


# ── T3: an ancestry read that cannot reach the top ⇒ report, not kill ────────────────────────
def t3_inconclusive_ancestry_reports_not_kills():
    b = Bed()
    # 7000's parent 7999 is ABSENT from the snapshot: the walk cannot reach the top.
    b.table([pytest_row(7000, 7999, etime="11:30:00"), LAUNCHD])
    r = b.run("--apply")
    assert_eq(r.returncode, 0, "T3 exit")
    assert_eq(b.kills(), [], "T3 an unreadable chain must never be signalled")
    assert_in(r.stdout, "INCONCLUSIVE", "T3 the verdict is INCONCLUSIVE")
    assert_in(r.stdout, "pid 7999 is not visible", "T3 the report names what was observed")
    assert_in(r.stdout, "gate 2: INCONCLUSIVE", "T3 the reason names the inconclusive gate")


# ── T4: the constants the code DECIDES with are the ones the report PRINTS ───────────────────
def _load_module(path=None):
    path = path or SCRIPT
    spec = importlib.util.spec_from_file_location("orphan_reap_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def t4_constants_are_the_ones_in_use():
    mod = _load_module()
    # The DRIFT property first: whatever the constant is, the header must be formatted FROM it.
    # (A mutation that hardcodes the printed literal must fail HERE, not on the value assertion.)
    header = mod.cpu_header(mod.WINDOW_S)
    assert_in(header, f"tolerance={mod.TOLERANCE_S:.2f}s", "T4 the header prints the constant")
    assert_in(header, f"window={mod.WINDOW_S:.1f}s", "T4 the header prints the window constant")
    assert_eq(mod.TOLERANCE_S, 0.10, "T4 TOLERANCE_S")
    assert_eq(mod.WINDOW_S, 20.0, "T4 WINDOW_S")
    assert_eq(mod.MIN_WINDOW_S, 10.0, "T4 MIN_WINDOW_S")

    # BOUNDARY: the decision, not the prose. 0.09s is parked; 0.11s is not.
    b = Bed()
    b.table([pytest_row(8000, 1, cpu="00:00.00", etime="11:30:00"), LAUNCHD],
            after=[pytest_row(8000, 1, cpu="00:00.09", etime="11:30:00"), LAUNCHD])
    parked = b.run()
    assert_in(parked.stdout, "PARKED +0.09s", "T4 a 0.09s delta over the window IS parked")
    assert_in(parked.stdout, "window=1.0s", "T4 the header states the window actually used")

    b2 = Bed()
    b2.table([pytest_row(8100, 1, cpu="00:00.00", etime="11:30:00"), LAUNCHD],
             after=[pytest_row(8100, 1, cpu="00:00.11", etime="11:30:00"), LAUNCHD])
    alive = b2.run()
    assert_in(alive.stdout, "ALIVE +0.11s", "T4 a 0.11s delta is ALIVE, not parked")
    assert_not_in(alive.stdout, "=> REAP", "T4 an alive process is never selected")

    # A sub-floor window is refused unless signalling is redirected (a spin needs time to show).
    b3 = Bed()
    b3.table([pytest_row(8200, 1), LAUNCHD])
    no_kill = b3.env_over(KILL_BIN="")
    refused = b3.run(window="2", env=no_kill)
    assert_eq(refused.returncode, 2, "T4 a sub-floor window without a kill shim is a usage error")
    assert_in(refused.stderr, "MIN_WINDOW_S", "T4 the refusal names the floor")
    assert_eq(b3.kills(), [], "T4 a refused pass signals nothing")


def t4b_unparseable_cpu_is_inconclusive():
    b = Bed()
    b.table([pytest_row(8300, 1, cpu="garbage", etime="11:30:00"), LAUNCHD],
            after=[pytest_row(8300, 1, cpu="garbage", etime="11:30:00"), LAUNCHD])
    r = b.run("--apply")
    assert_eq(r.returncode, 0, "T4b exit")
    assert_eq(b.kills(), [], "T4b an unreadable CPU time is not a zero delta")
    assert_in(r.stdout, "gate 1 inconclusive", "T4b gate 1 refuses")


# ── T5: gate 3 is DATA — a 40m rail is normal, an 11h30m shard is 26.5x its class ────────────
def t5_distribution_is_class_data():
    b = Bed()
    rail = row(9000, 1, "/bin/bash", f'/bin/bash -c "{OWNER}/scripts/admin-merge.sh 9001"',
               etime="00:40:00")
    b.table([rail, LAUNCHD])
    r = b.run("--apply")
    assert_eq(b.kills(), [], "T5 a 40m merge rail is normal — never reaped")
    assert_in(r.stdout, "class=merge-rail", "T5 the class comes from argv")
    assert_in(r.stdout, "plausible", "T5 a 40m rail is inside its own distribution")
    assert_in(r.stdout, "gate 3: plausible", "T5 gate 3 is the reason")

    b2 = Bed()
    b2.table([pytest_row(9100, 1, etime="11:30:00"), LAUNCHD])
    r2 = b2.run()
    assert_in(r2.stdout, "26.5x", "T5 an 11h30m shard is 26.5x its 26m class tail")
    assert_in(r2.stdout, "OVERLONG", "T5 past its own distribution")
    assert_in(r2.stdout, "source:", "T5 the data carries the measurement it came from")


def t5b_no_measured_distribution_is_reported():
    b = Bed()
    b.table([row(9200, 1, "/usr/bin/python3.12",
                 f"{OWNER}/.venv/bin/uvicorn main:app", etime="12:00:00"), LAUNCHD])
    r = b.run("--apply")
    assert_eq(b.kills(), [], "T5b a class with no measured distribution is never reaped")
    assert_in(r.stdout, "class=test-server", "T5b the class comes from argv")
    assert_in(r.stdout, "gate 3: INCONCLUSIVE", "T5b gate 3 refuses on no data")
    assert_in(r.stdout, "NO measured distribution", "T5b the missing measurement is named")
    # the pure function, for the arm the candidate regex cannot currently reach (defensive)
    mod = _load_module()
    assert_eq(mod.distribution(None, 3600.0).verdict, "INCONCLUSIVE",
              "T5b an unmatched class is INCONCLUSIVE")


# ── T6: designed daemon / diagnostic value ⇒ REPORTED, never killed ─────────────────────────
def t6_designed_daemon_and_diagnostics_are_reported():
    b = Bed()
    b.table([pytest_row(9500, 1, etime="11:30:00", args=f"{OWNER}/.venv/bin/python -m pytest --loop"),
             LAUNCHD])
    r = b.run("--apply")
    assert_eq(b.kills(), [], "T6 a daemon-ish argv is never reaped")
    assert_in(r.stdout, "daemon-ish argv", "T6 the evidence is named")

    b2 = Bed()
    b2.table([pytest_row(9600, 1, etime="11:30:00"), LAUNCHD])
    out = os.path.join(b2.tmp, "out.txt")
    open(out, "w").write("still working\n")           # written NOW ⇒ recent
    b2.lsof_for(9600, [f"python3.12 9600 user 3w REG 1,2 12 999 {out}"])
    r2 = b2.run("--apply")
    assert_eq(b2.kills(), [], "T6 a process with a recent write is never reaped")
    assert_in(r2.stdout, "output written", "T6 gate 5 names the recent write")

    b2b = Bed()
    b2b.table([pytest_row(9650, 1, etime="11:30:00"), LAUNCHD])
    with open(os.path.join(b2b.home, ".pi", "agent", "state", "publisher.pid"), "w") as fh:
        fh.write("9650\n")
    r2b = b2b.run("--apply")
    assert_eq(b2b.kills(), [], "T6 a pid that a pidfile names is never reaped")
    assert_in(r2b.stdout, "DESIGNED — pidfile publisher.pid", "T6 the pidfile is named")

    b2c = Bed()
    b2c.table([pytest_row(9660, 1, etime="11:30:00"), LAUNCHD])
    b2c.lsof_for(9660, ["python3.12 9660 user 4u unix 0x0 0t0 12345 ->"])
    r2c = b2c.run("--apply")
    assert_eq(b2c.kills(), [], "T6 a process holding a listening socket is never reaped")
    assert_in(r2c.stdout, "holds a listening socket", "T6 the listener is named")

    b2d = Bed()
    b2d.table([pytest_row(9670, 1, etime="11:30:00"), LAUNCHD])
    broken_lsof = os.path.join(b2d.tmp, "broken-lsof")
    with open(broken_lsof, "w") as fh:
        fh.write("#!/usr/bin/env bash\nexit 2\n")
    os.chmod(broken_lsof, 0o755)
    r2d = b2d.run("--apply", env=b2d.env_over(LSOF_BIN=broken_lsof))
    assert_eq(b2d.kills(), [], "T6 an unreadable lsof must signal nothing")
    assert_in(r2d.stdout, "INCONCLUSIVE — open files unreadable", "T6 the inconclusive arm is named")

    b3 = Bed()
    b3.table([pytest_row(9700, 1, etime="11:30:00",
                         args=f"{OWNER}/.venv/bin/python -m pytest tests/ #1244"), LAUNCHD])
    r3 = b3.run("--apply")
    assert_eq(b3.kills(), [], "T6 a candidate naming a work item is never reaped")
    assert_in(r3.stdout, "names a work item (#1244)", "T6 the reference is quoted")
    assert_in(r3.stdout, "gate 6: DIAGNOSTIC", "T6 gate 6 is the reason")

    b4 = Bed()
    b4.table([pytest_row(9800, 1, etime="11:30:00"), LAUNCHD])
    sess = os.path.join(b4.home, ".pi", "agent", "sessions", "abc.jsonl")
    os.makedirs(os.path.dirname(sess), exist_ok=True)
    open(sess, "w").write("{}\n")
    b4.lsof_for(9800, [f"python3.12 9800 user 5w REG 1,2 9 998 {sess}"])
    r4 = b4.run("--apply")
    assert_eq(b4.kills(), [], "T6 a candidate holding a lane transcript is never reaped")
    assert_in(r4.stdout, "holds a lane transcript", "T6 the transcript is named")


# ── T7: an unreadable launchctl is INCONCLUSIVE, not "nothing is registered" ────────────────
def t7_unreadable_launchctl_fails_closed():
    b = Bed()
    b.table([pytest_row(9900, 1, etime="11:30:00"), LAUNCHD])
    r = b.run("--apply", env=b.env_over(FAKE_LAUNCHCTL_MODE="fail"))
    assert_eq(r.returncode, 3, "T7 an unreadable launchctl exits 3 (fail-closed, as documented)")
    assert_eq(b.kills(), [], "T7 an unreadable launchctl must signal NOTHING (fail closed)")
    assert_in(r.stdout, "gate 4: INCONCLUSIVE", "T7 the inconclusive gate is named")
    assert_in(r.stdout, "launchctl` could not be read", "T7 the observation is named")

    # the GUI-domain read fails but the bare read answers: still a complete answer (fallback)
    b1c = Bed()
    b1c.table([pytest_row(9930, 1, etime="11:30:00"), LAUNCHD])
    r1c = b1c.run(env=b1c.env_over(FAKE_LAUNCHCTL_MODE="no-gui"))
    assert_in(r1c.stdout, "1 registered job(s)", "T7 the bare-domain fallback still answers")

    # the two domains DISAGREE: the candidate is registered in the caller's GUI domain (where the
    # owner's managed jobs live) and invisible in the bare read. Asking the GUI domain by name is
    # what makes the difference — reading only the default would reap a managed job (cycle 3, P2).
    b1d = Bed()
    b1d.table([pytest_row(9940, 1, etime="12:00:00"), LAUNCHD])
    r1d = b1d.run("--apply", env=b1d.env_over(
        FAKE_LAUNCHCTL_MODE="by-domain",
        FAKE_LAUNCHCTL_GUI=b1d._fixture("lc-gui", "PID\tStatus\tLabel\n9940\t0\tcom.owner.job\n"),
        FAKE_LAUNCHCTL_BARE=b1d._fixture("lc-bare", "PID\tStatus\tLabel\n999\t0\tcom.decoy\n")))
    assert_eq(b1d.kills(), [], "T7 a job registered in the GUI domain must never be signalled")
    assert_in(r1d.stdout, "gate 4_launchd     REGISTERED", "T7 the GUI-domain registration is read")

    # rc=0 but NO pid rows: ambiguous (an ssh/cron domain cannot see the caller's jobs) => refuse
    b1b = Bed()
    b1b.table([pytest_row(9920, 1, etime="11:30:00"), LAUNCHD])
    r1b = b1b.run("--apply", env=b1b.env_over(
        FAKE_LAUNCHCTL=b1b._fixture("launchctl-empty", "PID\tStatus\tLabel\n-\t0\tsome.job\n")))
    assert_eq(b1b.kills(), [], "T7b rc=0 with no pid rows must signal nothing")
    assert_in(r1b.stdout, "gate 4: INCONCLUSIVE", "T7b an empty launchctl parse is INCONCLUSIVE")

    # a host with no launchctl at all (a Linux cell) is the same refusal, named differently
    b2 = Bed()
    b2.table([pytest_row(9910, 1, etime="11:30:00"), LAUNCHD])
    r2 = b2.run("--apply", env=b2.env_over(LAUNCHCTL_BIN=os.path.join(b2.tmp, "no-such-launchctl")))
    assert_eq(b2.kills(), [], "T7 a host without launchctl signals nothing")
    assert_in(r2.stdout, "no launchctl on this host", "T7 the missing probe is named as such")
    assert_eq(r2.returncode, 0, "T7 an INAPPLICABLE probe is not an error (no alarm fatigue)")
    assert_in(r2.stdout, "INAPPLICABLE", "T7 the gate is reported as inapplicable, not failed")


# ── T8: the dry run is the DEFAULT, and every decision is logged with its evidence ──────────
def t8_dry_run_default_and_the_decision_log():
    b = Bed()
    b.table([pytest_row(6000, 1, etime="11:30:00"), LAUNCHD])
    r = b.run()
    assert_eq(r.returncode, 0, "T8 exit")
    assert_eq(b.kills(), [], "T8 the default invocation reaps NOTHING")
    assert_in(r.stdout, "mode=dry-run", "T8 the mode is stated")
    assert_in(r.stdout, "nothing signalled", "T8 the dry run says nothing was signalled")

    (rec,) = b.log_lines()
    for key in ("ts", "mode", "pid", "comm", "class", "age_s", "age", "cpu_delta_s", "window_s",
                "tolerance_s", "ancestry", "ancestry_path", "gates", "verdict", "reason"):
        if key not in rec:
            raise AssertionError(f"T8 the decision log is missing {key!r}: {rec}")
    assert_eq(rec["mode"], "dry-run", "T8 logged mode")
    assert_eq(rec["class"], "pytest-shard", "T8 logged class")
    assert_eq(rec["tolerance_s"], 0.10, "T8 logged tolerance")
    for gate in ("1_cpu", "2_ancestry", "3_expected", "4_launchd", "5_designed", "6_diagnostic"):
        if gate not in rec["gates"]:
            raise AssertionError(f"T8 gate {gate!r} missing from the log: {rec['gates']}")


# ── T9: an unreadable process table aborts the pass (exit 3, nothing signalled) ─────────────
def t9_unreadable_ps_fails_closed():
    b = Bed()
    b.table([pytest_row(6000, 1, etime="11:30:00"), LAUNCHD])
    broken = os.path.join(b.tmp, "broken-ps")
    with open(broken, "w") as fh:
        fh.write("#!/usr/bin/env bash\nexit 1\n")
    os.chmod(broken, 0o755)
    r = b.run("--apply", env=b.env_over(PS_BIN=broken))
    assert_eq(r.returncode, 3, "T9 an unreadable process table exits 3 (fail closed)")
    assert_eq(b.kills(), [], "T9 nothing is signalled when the table is unreadable")


def t11_population_is_this_owner_only():
    mod = _load_module()
    home = os.path.expanduser("~").rstrip("/")
    if not mod.OURS.search(home + "/GitHub/tortoise/.venv/bin/python -m pytest"):
        raise AssertionError(f"T11 the caller's own checkout must be in the population: "
                             f"{mod.OURS.pattern!r} vs {home}")
    if not mod.OURS.search("/Users/someoneelse/Documents/GitHub/x/.venv/bin/python -m pytest"):
        return
    raise AssertionError("T11 another user's checkout must not be in this owner's population")


def t10_unparseable_etime_is_inconclusive():
    b = Bed()
    b.table([row(6300, 1, "/usr/bin/python3.12",
                 f"{OWNER}/.venv/bin/python -m pytest tests/ -q", etime="not-a-time"), LAUNCHD])
    r = b.run("--apply")
    assert_eq(r.returncode, 0, "T10 a malformed etime must not crash the pass (it used to exit 1)")
    assert_eq(b.kills(), [], "T10 an unknown age must not authorize a reap")
    assert_in(r.stdout, "gate 3_expected    INCONCLUSIVE", "T10 gate 3 refuses on an unknown age")
    assert_in(r.stdout, "not parseable", "T10 the observation is named")
    assert_in(r.stdout, "age=age-unknown", "T10 an unknown age renders as unknown, never negative")


TESTS = [
    ("T1_human_ancestor_never_reaped", t1_human_ancestor_never_reaped),
    ("T1a_interactive_shell_ancestor", t1a_interactive_shell_ancestor_never_reaped),
    ("T1b_terminal_marker_directly", t1b_terminal_marker_directly),
    ("T1c_login_marker_directly", t1c_login_marker_directly),
    ("T1d_own_argv_is_not_an_ancestor", t1d_own_argv_is_not_an_ancestor),
    ("T1e_own_tty_is_inconclusive", t1e_own_tty_is_inconclusive),
    ("T2_daemonised_ppid1_selected", t2_daemonised_ppid1_selected_only_on_apply),
    ("T2b_reused_pid_is_suppressed", t2b_reused_pid_is_suppressed),
    ("T2c_reused_pid_with_identical_argv", t2c_reused_pid_with_identical_argv),
    ("T2d_sigkill_arm_is_identity_checked", t2d_sigkill_arm_is_identity_checked),
    ("T2e_genuine_survivor_gets_sigkill", t2e_genuine_survivor_gets_sigkill),
    ("T3_inconclusive_ancestry_reports", t3_inconclusive_ancestry_reports_not_kills),
    ("T4_constants_are_the_ones_in_use", t4_constants_are_the_ones_in_use),
    ("T4b_unparseable_cpu_is_inconclusive", t4b_unparseable_cpu_is_inconclusive),
    ("T5_distribution_is_class_data", t5_distribution_is_class_data),
    ("T5b_no_measured_distribution_is_reported", t5b_no_measured_distribution_is_reported),
    ("T6_daemons_and_diagnostics_reported", t6_designed_daemon_and_diagnostics_are_reported),
    ("T7_unreadable_launchctl_fails_closed", t7_unreadable_launchctl_fails_closed),
    ("T8_dry_run_default_and_decision_log", t8_dry_run_default_and_the_decision_log),
    ("T9_unreadable_ps_fails_closed", t9_unreadable_ps_fails_closed),
    ("T10_unparseable_etime_is_inconclusive", t10_unparseable_etime_is_inconclusive),
    ("T11_population_is_this_owner_only", t11_population_is_this_owner_only),
]

# ── the mutation matrix: one per gate, each paired with the test that must catch it ──────────
# (name, [(old, new), ...], paired test). A mutation that the paired test does NOT catch is a
# suite failure, printed as MISSED — the evidence, not the claim.
MUTATIONS = [
    ("M1_gate1_parked_always",
     [("0.0 <= delta < TOLERANCE_S", "True  # MUTANT: gate 1 always passes")],
     "T4_constants_are_the_ones_in_use"),
    ("M2_gate2_human_markers_gone",
     [("            for pat in (HUMAN_PATH, HUMAN_WORD):",
       "            for pat in ():  # MUTANT: no human is ever recognised")],
     "T1b_terminal_marker_directly"),
    ("M2b_gate2_human_shell_arm_gone",
     [("if base in SHELLS and r[\"uid\"] == str(os.getuid()) and interactive:",
       "if False:  # MUTANT: an interactive shell is not a human")],
     "T1a_interactive_shell_ancestor"),
    ("M3_gate2_inconclusive_reads_as_clean",
     [('elif anc.verdict != "NO-HUMAN":',
       'elif anc.verdict.startswith("HUMAN"):  # MUTANT: a blind walk passes gate 2')],
     "T3_inconclusive_ancestry_reports"),
    ("M4_gate3_distribution_ignored",
     [('elif dist.verdict != "OVERLONG":', 'elif False:  # MUTANT: gate 3 never refuses')],
     "T5_distribution_is_class_data"),
    ("M5_gate4_inconclusive_but_decides_anyway",
     # ⛔ THE DECISION-CHAIN ARM, ANCHORED WHERE IT ACTUALLY LIVES. A previous form of this mutation
     # used the bare `elif reg is None:` anchor and hit the DISPLAY block (which is earlier in
     # `decide()`), so the report said INCONCLUSIVE while the decision still refused — a mutant that
     # changed nothing, reported as "caught". This anchor spans the reason assignment, so the display
     # and the decision cannot disagree (review cycles 3 and 4, P3).
     [("""    elif reg is None:
        d.reason = ("gate 4: INCONCLUSIVE — `launchctl` could not be read, so a managed job "
                    "cannot be ruled out")""",
       """    elif False:  # MUTANT: the display says INCONCLUSIVE, the decision decides anyway
        pass""")],
     "T7_unreadable_launchctl_fails_closed"),
    ("M6_gate5_designed_daemon_ignored",
     [("    elif designed:", "    elif False:  # MUTANT: gate 5 never refuses")],
     "T6_daemons_and_diagnostics_reported"),
    ("M7_dry_run_is_not_the_default",
     [('ap.add_argument("--apply", action="store_true",',
       'ap.add_argument("--apply", action="store_true", default=True,')],
     "T8_dry_run_default_and_decision_log"),
    ("M8_tolerance_drifts",
     [("\nTOLERANCE_S = 0.10          #", "\nTOLERANCE_S = 0.50          # MUTANT: tolerance drifts")],
     "T4_constants_are_the_ones_in_use"),
    ("M9_report_prints_a_literal_not_the_constant",
     # DRIFT ONLY: the constant is untouched; the header hardcodes a different literal. This is the
     # defect the claim names, and it must fail the header assertion (review P2 — the previous form
     # also moved the constant, so the catch could be attributed to the value assertion instead).
     [("tolerance={TOLERANCE_S:.2f}s", "tolerance={0.25:.2f}s")],
     "T4_constants_are_the_ones_in_use"),
    ("M11_gate3_no_data_reads_as_overlong",
     [('        return Distribution("INCONCLUSIVE",\n'
       '                            f"{klass.name} has NO measured distribution',
       '        return Distribution("OVERLONG",  # MUTANT: no data reads as past its distribution\n'
       '                            f"{klass.name} has NO measured distribution')],
     "T5b_no_measured_distribution_is_reported"),
    ("M12_gate5_listener_arm_gone",
     [("    if probe.listener:", "    if False:  # MUTANT: a held listening socket is ignored")],
     "T6_daemons_and_diagnostics_reported"),
    ("M13_window_floor_removed",
     [("MIN_WINDOW_S = 10.0", "MIN_WINDOW_S = 0.0  # MUTANT: any window is legal")],
     "T4_constants_are_the_ones_in_use"),
    ("M23_sigkill_uses_a_stale_snapshot",
     [("    for d in signalled:\n        fresh = proc_table()",
       "    for d in signalled:\n        fresh = fresh  # MUTANT: reuse one shared snapshot")],
     "T2d_sigkill_arm_is_identity_checked"),
    ("M24_unreadable_launchctl_reads_as_inapplicable",
     [("    launchd_unreadable = reg is None and launchd_available()",
       "    launchd_unreadable = False  # MUTANT: a failed read is not a failure")],
     "T7_unreadable_launchctl_fails_closed"),
    ("M19_launchd_reads_default_domain_only",
     [('[LAUNCHCTL_BIN, "list", f"gui/{os.getuid()}"]', '[LAUNCHCTL_BIN, "list"]')],
     "T7_unreadable_launchctl_fails_closed"),
    ("M20_own_tty_arm_removed",
     [('    if anc.verdict == "NO-HUMAN" and not NO_TTY.match(before["tty"]):',
       '    if False:  # MUTANT: a reparented process owning a tty is walkable')],
     "T1e_own_tty_is_inconclusive"),
    ("M21_unparseable_cpu_reads_as_zero",
     [("    delta = -1.0 if (t_before < 0 or t_after < 0) else t_after - t_before",
       "    delta = t_after - t_before  # MUTANT: -1 - -1 == 0 == PARKED")],
     "T4b_unparseable_cpu_is_inconclusive"),
    ("M22_lsof_unreadable_ignored",
     [("    if probe.unreadable:", "    if False:  # MUTANT: an unreadable lsof reads as no daemon trace")],
     "T6_daemons_and_diagnostics_reported"),
    ("M5_gate4_unreadable_returns_empty_set",
     [("        return None\n    r = read", "        return set()  # MUTANT: unreadable == nothing registered")],
     "T7_unreadable_launchctl_fails_closed"),
    ("M15_empty_launchctl_parse_reads_as_clean",
     [("    if not pids:", "    if False:  # MUTANT: an empty parse reads as 'nothing registered'")],
     "T7_unreadable_launchctl_fails_closed"),
    ("M16_pid_reuse_etime_arm_removed",
     [('    if etime_seconds(row["etime"]) + 1.0 < d.ident[2]:',
       '    if False:  # MUTANT: only comm/argv are compared')],
     "T2c_reused_pid_with_identical_argv"),
    ("M17_etime_parser_raises_again",
     # anchored inside etime_seconds (cpu_seconds has the same `except` shape earlier in the file)
     [("        return days * 86400 + sum(v * (60 ** i) for i, v in enumerate(reversed(parts)))\n"
       "    except Exception:\n        return -1.0",
       "        return days * 86400 + sum(v * (60 ** i) for i, v in enumerate(reversed(parts)))\n"
       "    except Exception:\n        raise  # MUTANT: one malformed row kills the pass")],
     "T10_unparseable_etime_is_inconclusive"),
    ("M18_human_word_marker_unbounded_on_own_argv",
     # The defect the review found is the PAIR: an unbounded `login` substring AND the candidate's
     # own argv being scanned. Either alone is invisible (the ancestor-only guard and the word
     # boundaries each already block it), so the mutation reintroduces both.
     [('HUMAN_WORD = re.compile(r"(?<![\\w.-])(?:login|sshd|tmux|screen)(?![\\w.-])")',
       'HUMAN_WORD = re.compile(r"login|sshd|tmux|screen")  # MUTANT: unbounded substring'),
      ("        if len(path) > 1:",
       "        if True:  # MUTANT: the candidate's own argv is scanned")],
     "T1d_own_argv_is_not_an_ancestor"),
    ("M14_pid_reuse_guard_removed",
     [("        ok, why = still_same(d, fresh)\n        if not ok:",
       "        ok, why = still_same(d, fresh)\n        if False:  # MUTANT: signal by pid alone")],
     "T2b_reused_pid_is_suppressed"),
    ("M10_gate6_diagnostic_ignored",
     [("    elif diagnostic:", "    elif False:  # MUTANT: gate 6 never refuses")],
     "T6_daemons_and_diagnostics_reported"),
]


def _source(path=None):
    path = path or SCRIPT
    with open(path) as fh:
        return fh.read()


def _mutate(text, edits, name):
    for old, new in edits:
        if old not in text:
            raise AssertionError(f"{name}: mutation anchor not found in the script: {old!r}")
        text = text.replace(old, new, 1)
    return text


def run_tests(selected=None):
    failed = 0
    for name, fn in TESTS:
        if selected and name not in selected:
            continue
        try:
            fn()
            print(f"  PASS  {name}")
        except AssertionError as e:
            failed += 1
            print(f"  FAIL  {name}: {e}")
        except Exception as e:  # noqa: BLE001 — a crashed test is a failed test
            failed += 1
            print(f"  ERROR {name}: {type(e).__name__}: {e}")
    return failed


def run_mutations():
    """Reintroduce each defect into a TEMP copy and require the paired test to go RED."""
    missed = []
    for name, edits, paired in MUTATIONS:
        tmp = tempfile.mkdtemp(prefix="orphan-reap-mutant-")
        atexit.register(lambda p=tmp: shutil.rmtree(p, ignore_errors=True))
        path = os.path.join(tmp, "orphan-reap.py")
        with open(path, "w") as fh:
            fh.write(_mutate(_source(), edits, name))
        os.chmod(path, 0o755)
        globals()["SCRIPT"] = path
        print(f"  MUTANT {name} → {paired}")
        red = run_tests(selected={paired}) > 0
        # restore the shipped script for the next iteration
        globals()["SCRIPT"] = os.environ.get("ORPHAN_REAP_UNDER_TEST") or os.path.normpath(
            os.path.join(HERE, "orphan-reap.py"))
        if red:
            print(f"  CAUGHT {name}")
        else:
            missed.append(name)
            print(f"  MISSED {name} — the paired test still passes against the mutant")
    print(f"MUTATIONS={len(MUTATIONS)} CAUGHT={len(MUTATIONS) - len(missed)} MISSED={len(missed)}")
    return len(missed)


def main() -> int:
    argv = sys.argv[1:]
    if "--mutations" in argv:
        return 1 if run_mutations() else 0
    print(f"suite: {os.path.basename(__file__)} against {SCRIPT}")
    failed = run_tests()
    total = len(TESTS)
    print(f"TESTS={total} PASSED={total - failed} FAILED={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
