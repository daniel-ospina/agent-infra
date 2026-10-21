#!/usr/bin/env python3
"""orphan-reap.py — reap ORPHANED test/tooling processes, under the gates, in code.

WHY THIS EXISTS
`orphan-scan.py` only reports (and is pinned to one lane's needle); `embedded_orphans.py` is a
census; `run_reaper.py` cancels GitHub Actions runs, not processes. So the class that #5035
documented — a test process whose parent died, silently promoted to `ppid 1` where **nothing owns
it**, free to run for two days — had NO reaper. The three-gate walk that killed the 43h48m pytest
was done **by hand**. This is that walk, as code, with the dry-run as the default.

    #5035's own words: "`ppid 1` is a silent promotion to 'nobody owns this.'"

⛔ WHY THE RULE MUST BE HERE AND NOT IN PROSE (#1244, the issue this file answers)
The 2026-09-18 near-miss applied a *prose* rule — "zero CPU delta across consecutive checks ⇒
PARKED ⇒ may be reaped" — to pids 10589 (`node`) / 10607 (`codex`), textbook parked at 0.00 s and
0.02 s across 25 s. Their chain ended at a **human's hand-opened terminal**
(`Terminal.app → login -pf … → -zsh → node → codex`). Nothing in code evaluated that rule, so
nothing could be tested. #1244 offered two routes: (1) move the rule into code and make an agent
call a tool that answers SELECT | REJECT | UNKNOWN **with its evidence**, or (2) weaken the prose to
a prohibition. This file takes route (1) on the **existing** carrier — `scripts/orphan-reap.py` is
already the repo-documented owner of the ancestry, launchd and designed-daemon gates
(`docs/ops/fleet-harness-baseline.md:47`, `scripts/orchestrator-harness/README.md` §6.5.3), so route
(1) does not create a second reaper. Every candidate now carries a per-gate verdict and a logged
reason, in a machine-readable line as well as prose.

THE THREE REQUIRED GATES, IN ORDER (all three must pass; any unclear read ⇒ REPORT, never reap)
  1. ZERO CPU DELTA over a STATED window, with a STATED numeric tolerance. Both are printed at the
     top of every pass and in every log line, and they are the constants the code decides with
     (`WINDOW_S`, `TOLERANCE_S` below — `scripts/orphan_reap.test.py` pins the boundary so prose and
     behaviour cannot drift). The window is justified in `PERMITTED EVENTS` below: a sub-tolerance
     delta has the SAME signature from three different things, so gate 1 is NECESSARY and never
     sufficient — gate 2 is what makes a reap safe.
  2. ANCESTRY WALK TO THE TOP. Any `Terminal` / `iTerm` / `login` / `sshd` / terminal-multiplexer
     ancestor — or an ancestor that is an interactive shell owned by the caller's uid — means the
     process belongs to a HUMAN: never touch it, however parked it looks. **`ppid 1` proves
     nothing on its own**: a daemonising service reparents to 1 BY DESIGN, and on Linux a
     `PR_SET_CHILD_SUBREAPER` process (prctl(2)) adopts orphans so their ppid is the *subreaper*,
     not 1. If the chain cannot be walked to the top, the verdict is INCONCLUSIVE and the candidate
     is REPORTED — an incomplete walk must never read as a clean walk (README §6.5.3: "If either
     read is ambiguous, REPORT and do not reap").
  3. PROGRESS AGAINST THE PROCESS'S OWN EXPECTED DISTRIBUTION. Age is compared with what THAT CLASS
     of process costs, encoded as DATA (`PROC_CLASSES`) with the measurement each bound comes from
     — not as an `if elapsed >= N` statement. A class with NO measured distribution is INCONCLUSIVE
     (fail closed): the reaper may not invent a distribution to justify a kill.
  4. ⛔ LAUNCHD-REGISTRATION GATE (added 2026-10-12) — if the pid is a REGISTERED launchd job,
     it is a managed daemon with an owner (the owner's menu-bar app, minutes-mcp, cmux...).
     `ppid 1` looks identical. NEVER reap one. Without this gate the reaper kills the owner's
     own UI. Three outcomes, and they are NOT the same thing:
       * REGISTERED / unmanaged  — a clean read (the caller's `gui/<uid>` domain first, because a
         bare read from an ssh/cron domain cannot see the owner's GUI jobs);
       * INAPPLICABLE — this host has no `launchctl` at all (a Linux cell). The gate cannot be
         evaluated, so NOTHING is reaped, but it is reported as INAPPLICABLE and does not raise an
         error: an inapplicable probe is not a failure (the same rule `tools/fleet/fleet-health.py`
         records for its own reaper scan). ⛔ It does mean this reaper cannot reap on a Linux host
         today — a systemd unit equivalent is the missing half, and pretending otherwise is the
         fail-open this bullet exists to prevent;
       * INCONCLUSIVE — `launchctl` exists but could not be read. Nothing is reaped and the pass
         exits 3 (fail-closed), because a resolver that fails open is how a reaper kills a daemon
         it could not see.
  5. ⛔ DESIGNED-DAEMON GATE (added 2026-10-12, AFTER THE FIRST DRY RUN WAS WRONG) — gates 1-4
     passed on THREE processes and ALL THREE were wrong to reap:
       * `live-workspaces-publisher.py` — `--loop` in argv, a pidfile, and its output file
         written 10 minutes ago. A LIVE daemon that merely got reparented, not an orphan;
       * two `redis-server` processes whose unix sockets had a LIVE CLIENT (`lsof` showed a
         second holder on each) — reaping them would have broken a running test.
     Intent is not visible in `ppid`, CPU, or elapsed time. So: pidfile naming the pid, a
     daemon-ish flag in argv, an output file touched recently, or ANY live holder of a socket
     it owns  =>  DESIGNED => never reap.
  6. DIAGNOSTIC VALUE (#1244's "reapable != right to reap", made mechanical) — a candidate whose
     cwd/argv names an issue or PR reference, or that holds a `.jsonl` lane transcript, or that
     wrote a file in the last `RECENT_WRITE_S`, is REPORTED and never killed. Evidence beats
     tidiness: a 12h-parked pytest that is the only remaining witness of a failed lane is worth
     more than the core it holds. (Whether the named issue is still OPEN would need a `gh` read;
     a reaper that runs on a loaded box may not pay that, so it refuses instead of guessing.)

PERMITTED EVENTS — why the window is what it is (gate 1's justification)
`ps -o time` resolves to CENTISECONDS (10 ms), so the smallest observable delta is 0.01 s.
`TOLERANCE_S = 0.10 s` is ten ticks: ten times the quantum, which means a reading inside it cannot
be manufactured by clock rounding — an idle process reads exactly `0.00`, not `0.00 ± 0.01`.
`WINDOW_S = 20 s` is chosen so that a 1 Hz-ish wake (a prompt redraw, a spinner tick, a timer
callback) accumulates ~20 wakes, i.e. it reaches the tolerance band from below. That is deliberate
and it is the whole point: **a human's prompt redraw, a parked fork child, and a timer wake have the
same signature at this resolution**, so gate 1 can never authorize on its own. It is NECESSARY
(a spinning 43h pytest adds hundreds of centiseconds per second — #5035 measured +19.44 s over
30 s) and gate 2 is SUFFICIENT (the recorded rule: "Parked CPU is necessary; ancestry is the
SUFFICIENT guard"). `MIN_WINDOW_S = 10 s` refuses a shorter window on any box that can really
signal, because a spin sampled over 0.2 s has had no time to diverge from parked — the short window
would turn gate 1's *necessity* into a false positive. A window below the floor is permitted ONLY
when `KILL_BIN` is redirected (a hermetic run, where no real process can be signalled).

REAPABLE != RIGHT TO REAP: a candidate with diagnostic value stays (gate 6). Evidence beats tidiness.

SIGNALLING IS IDENTITY-CHECKED, NOT PID-CHECKED. Between the decision snapshot and the signal — and
again between SIGTERM and the survivor re-check — a pid can be REUSED, and a `SIGKILL` then lands on
an unrelated same-uid process (a freshly spawned lane worker, on this fleet). Every signal is
therefore preceded by a FRESH read whose `comm`, `argv` AND elapsed time must still match the
candidate; anything that does not verify is a SUPPRESS (reported and logged), never a signal.

USAGE
    orphan-reap.py                 # dry run (default): report every candidate + gate reading
    orphan-reap.py --apply         # SIGTERM the ones that pass every gate, then verify gone
    orphan-reap.py --sample 20     # CPU sample window in seconds (default: WINDOW_S = 20)
    orphan-reap.py --include-any-owner   # do not require the path to be under YOUR Documents/GitHub

EXIT CODES
    0  the pass completed (including "nothing to reap" and "everything was refused")
    2  usage error (a window below the floor without a redirected kill, a bad flag)
    3  FAIL-CLOSED: a read the pass needed (the process table, or `launchctl`) was unavailable, so
       NOTHING was signalled and nothing was reported as clean

ENV SEAMS (shared vocabulary with `scripts/pi-reap-idle.sh`; unset in production)
    PS_BIN, KILL_BIN, LAUNCHCTL_BIN, LSOF_BIN   — the binaries used for the four reads/signals
    ORPHAN_REAP_STATE_DIR                       — where the decision log is written

EVERY DECISION IS LOGGED (requirement, and the reason a schedule can be trusted): one JSON line per
candidate to `$ORPHAN_REAP_STATE_DIR/orphan-reap-decisions.jsonl` carrying pid, class, age, cpu
delta, window, tolerance, the ancestry path and verdict, every gate outcome, the verdict and the
reason. An unreadable log is reported on stderr and never silently swallowed.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field

# ── gate 1: the STATED window and tolerance (printed in every pass and every log line) ───────
# See PERMITTED EVENTS in the header for the derivation of both numbers.
WINDOW_S = 20.0             # the sample window, seconds — 20 one-second wakes
TOLERANCE_S = 0.10          # PARKED ⇔ 0.00 ≤ delta < 0.10 s over the window (10 × the 10 ms quantum)
MIN_WINDOW_S = 10.0         # refuse a shorter window unless signalling is redirected (see header)
SETTLE_S = 3.0              # the grace between SIGTERM and the survivor re-check
RECENT_WRITE_S = 900.0      # gate 5/6: an output file written inside 15 min means "still working"
LAUNCHCTL_BUDGET_S = 8.0    # bound every launchctl call; an unbounded helper is an unbounded pass

# ── env seams (test-only; unset in production, where the real binaries are used) ─────────────
PS_BIN = os.environ.get("PS_BIN") or "ps"
KILL_BIN = os.environ.get("KILL_BIN") or ""          # set ⇒ signals go through this program
LAUNCHCTL_BIN = os.environ.get("LAUNCHCTL_BIN") or "launchctl"
LSOF_BIN = os.environ.get("LSOF_BIN") or "lsof"
STATE_DIR = (os.environ.get("ORPHAN_REAP_STATE_DIR")
             or os.path.join(os.path.expanduser("~"), ".pi", "agent", "state"))
DECISION_LOG = os.path.join(STATE_DIR, "orphan-reap-decisions.jsonl")

# ── the candidate class ───────────────────────────────────────────────────────────────────────
# Only things WE run inside our own checkouts. An Apple executable is never a candidate, and a
# launchd job is never a candidate (gate 4). Both exclusions are positive identification, so a
# new Apple helper that happens to sit at ppid 1 is reported-not-reaped rather than killed.
# A checkout THIS owner keeps (unanchored: `bash -c "cd <checkout> && pytest"` carries the path
# mid-argv, and an anchored match silently excluded every wrapped invocation).
# ⛔ THIS OWNER, NOT "ANY USER" (review cycle 3, P3): `/Users/[^/]+/…` matched every account's
# checkouts, so the tool's stated population ("ours") was wider than its authority — and the
# reaper runs as whoever invoked it. The caller's own home is the scope; the macOS Documents form
# is kept but pinned to the caller's USERNAME.
HOME_DIR = os.path.expanduser("~").rstrip("/")
OWNER_USER = os.path.basename(HOME_DIR)
OURS = re.compile(re.escape(HOME_DIR) + r"/|/Users/" + re.escape(OWNER_USER) + r"/Documents/GitHub/")
TESTISH = re.compile(r"pytest|^\.?/?.+\.venv/bin/python|uvicorn|gunicorn|/bin/bash -c ", re.I)
# ⛔ NOT IN THIS TOOL'S CLASS: embedded `redislite` redis-server processes. Another agent owner
# already exists for them — `tortoise/tools/embedded_orphans.py` (the bounded census), the launchd
# job `com.tortoise.embedded-reaper`, and issue #3599 — whose only_safe mode exists precisely
# because a stranded redis CAN still have a live client. Reaping them here would duplicate that
# logic and, measured 2026-10-12, would have broken a running test: `lsof` showed pid 72824 holding
# the socket of BOTH stranded servers. Leave them to their owner; do not widen this regex.
#
# ⛔ AND NOT interactive `pi` sessions either — they are another owner's population, and this tool
# deliberately does not become a peer reaper for them:
#   * tty'd `pi` REPL sessions            → `scripts/pi-reap-idle.sh` (hourly, ARMED, JSONL proof)
#   * `ppid 1` dispatch children          → `scripts/sweep-orphans.sh` (TASK_HEARTBEAT=1 identity)
#   * the general `ppid 1` orphan class   → the carrier under review in agent-infra PR #1863
# A process becomes a candidate HERE only when it is under one of our checkouts and shaped like
# test/shard tooling — the class that had no owner before #5035.
#
# ⛔ AND NOT `ppid 1` AS A PRECONDITION (removed 2026-10-21, #1244). The old filter required
# `ppid == 1`, which made GATE 2 UNREACHABLE BY CONSTRUCTION: if a candidate's parent IS launchd,
# its chain is `[candidate, launchd]` — there is no hop left in which a human terminal could
# appear. So the ancestry gate could never refuse anything, which is exactly #1244's finding about
# the prose rule ("#1207 gates the reaper, which could never have seen them"): a gate whose
# population excludes the case it exists for. Candidacy is now argv-shaped (test/shard tooling in
# our own checkouts) at ANY depth, and gate 2 — the walk, not the ppid — decides whether a human
# owns it. `ppid 1` is still reported per candidate; it is no longer evidence of anything.
# ⛔ TWO MARKER SHAPES, NOT ONE SUBSTRING TABLE (fresh-context review cycle 2, P3). macOS host apps
# are matched as case-sensitive substrings of a PATH (`…/Terminal.app/Contents/MacOS/Terminal`); the
# lowercase binaries `login(1)`, `sshd`, `tmux`, `screen` are matched as WORDS — the bare substring
# `login` also matches `pytest tests/test_login.py` and would permanently refuse an ordinary shard
# (a false BLOCK: safe, but it makes the tool silently useless). `login` AS A WORD is required
# because the real binary is comm="login", args="login -pf <user>" — a path-only marker misses it.
HUMAN_PATH = re.compile(r"Terminal|iTerm|Warp\.app|kitty\.app|Alacritty\.app|Hyper\.app|cmux\.app")
HUMAN_WORD = re.compile(r"(?<![\w.-])(?:login|sshd|tmux|screen)(?![\w.-])")
# An interactive shell owned by the caller's uid is also a human: `-zsh`/`-bash` are LOGIN shells
# (argv[0] carries the leading dash), and `login(1)`/`sshd` hand them to a person, not to a daemon.
SHELLS = {"-zsh", "zsh", "-bash", "bash", "sh", "-sh", "fish", "-fish", "tcsh", "-tcsh",
          "ksh", "-ksh", "dash", "-dash", "nu", "xonsh", "elvish"}
# "Interactive" is not a guess: a login shell (argv[0] carries the dash) is a human session by
# definition, and any other shell is one only when it OWNS A TTY (`ps -o tty`). That distinction is
# load-bearing on this fleet: every lane wrapper is `bash -c "<checkout>/scripts/…"` with no tty, so
# dropping the tty test would classify the fleet's own rail invocations as a human's shell and the
# tool would refuse everything it exists to reap (measured on the first live dry run, 2026-10-21).
NO_TTY = re.compile(r"^[-?()/0-9 ]*$")   # `??` (macOS), `?` (a Linux container), `-`; never a real tty


@dataclass(frozen=True)
class ProcClass:
    """One class of process, with the distribution ITS OWN measurements produced.

    `expected_s` is the class's own slow tail (not a global constant): the point past which the
    process is no longer doing what its class does. `source` is the measurement, stated so a
    reader can audit the number instead of trusting it. `expected_s is None` means "no measured
    distribution exists" — the verdict is then INCONCLUSIVE and the candidate is reported.

    ⛔ DATA, NOT IF-STATEMENTS (#1244's third gate). Adding a class is one row here; it must come
    with the measurement it is derived from, or it cannot authorize a reap.
    """
    name: str
    pattern: str
    expected_s: float | None
    source: str
    overlong_x: float = 4.0     # past the distribution when age > expected_s × overlong_x
    floor_s: float = 1800.0     # …and never before this many seconds, whatever the multiple says


# ⛔ ORDER IS PART OF THE DATA: `class_of()` takes the FIRST match, and a server is normally
# started as `.venv/bin/python -m uvicorn …` — so `pytest|\.venv/bin/python` would claim it and
# gate 3 would declare a long-lived server OVERLONG at 1.73h instead of INCONCLUSIVE (fresh-context
# review cycle 8, P2). The most SPECIFIC classes therefore come first; the interpreter-glob class is
# LAST of the ones that can match a `.venv/bin/python` argv.
PROC_CLASSES = (
    # A merge rail is the LONGEST legitimate thing on this box: measured 35-65m per PR. A 40m rail
    # is normal; past 4× its slow tail (4h20m) it is not a rail any more.
    ProcClass("merge-rail", r"admin-merge|atomic-land|merge-queue", 3900.0,
              "measured 35-65m rail (scripts/admin-merge.sh bound); 3900s = the 65m slow tail"),
    # No measured distribution: a server is long-lived BY DESIGN, so age says nothing about it.
    # Before `pytest-shard` on purpose — `-m uvicorn`/`-m gunicorn` is how the fleet starts them.
    ProcClass("test-server", r"uvicorn|gunicorn", None,
              "no measured distribution — a server does not finish by design"),
    # The slowest shard observed is 26m, which is exactly what `tools/run_reaper.py` derives its
    # per-shard CI bounds from over a GREEN population. An 11h30m single test is 26.5× that tail.
    ProcClass("pytest-shard", r"pytest|\.venv/bin/python", 1560.0,
              "slowest shard 26m (1560s) — the GREEN-population bound tools/run_reaper.py derives"),
    # No measured distribution: an ad-hoc shell's cost is whatever a human or an agent typed.
    ProcClass("shell-c", r"/bin/bash -c ", None,
              "no measured distribution — an ad-hoc shell has no cost envelope"),
)


# ── the reads ────────────────────────────────────────────────────────────────────────────────
def proc_table() -> dict[str, dict] | None:
    """The process table, or None when the read failed (fail closed — never an empty 'clean' pass)."""
    try:
        # ⛔ `command=` (argv only), NOT `comm=,args=`: `comm` on macOS is a full executable PATH,
        # which may contain SPACES, and a whitespace split cannot tell "…/My App/bin/x" from two
        # columns — it silently shifted every field after it. With `command` last, the numeric
        # columns are fixed and everything after them is one unbounded string (cycle 7, P3).
        r = subprocess.run([PS_BIN, "-Ao", "pid=,ppid=,uid=,tty=,pcpu=,time=,etime=,command="],
                           capture_output=True, text=True, timeout=120)
    except Exception:
        return None
    if r.returncode != 0 or not r.stdout.strip():
        return None
    rows: dict[str, dict] = {}
    for ln in r.stdout.splitlines():
        p = ln.split(None, 7)
        if len(p) < 7:
            continue
        command = p[7] if len(p) > 7 else ""
        comm = os.path.basename(command.split()[0]) if command.split() else ""
        rows[p[0]] = {"pid": p[0], "ppid": p[1], "uid": p[2], "tty": p[3], "pcpu": p[4],
                      "time": p[5], "etime": p[6], "comm": comm or "?", "args": command,
                      "command": command}
    return rows or None


def cpu_seconds(t: str) -> float:
    """`0:52.97` / `3124:47` / `01-19:48:27` -> seconds. Returns -1.0 when unparseable."""
    try:
        days = 0.0
        if "-" in t:
            d, t = t.split("-", 1)
            days = float(d)
        parts = [float(x) for x in t.split(":")]
        secs = sum(v * (60 ** i) for i, v in enumerate(reversed(parts)))
        return days * 86400 + secs
    except Exception:
        return -1.0


def etime_seconds(t: str) -> float:
    """`11:30:00` / `01-19:48:27` -> seconds. Returns -1.0 when unparseable (never raises).

    A raising parser would crash the whole pass with exit 1 on one malformed row — the opposite of
    this tool's contract, which is exit 3 with nothing signalled (review cycle 2, P3).
    """
    try:
        t = t.strip()
        days = 0.0
        if "-" in t:
            d, t = t.split("-", 1)
            days = float(d)
        parts = [float(x) for x in t.split(":")]
        return days * 86400 + sum(v * (60 ** i) for i, v in enumerate(reversed(parts)))
    except Exception:
        return -1.0


def launchd_pids() -> set[str] | None:
    """Gate 4. `launchctl list` prints PID/status/label. A pid present here is a MANAGED JOB.

    ⛔ AN UNREADABLE DOMAIN IS `None` (INCONCLUSIVE), never `set()`. The earlier code returned a
    sentinel that every caller then failed to check, so an unreadable `launchctl` silently read as
    "nothing is registered" — the fail-OPEN direction, on the one gate that protects the owner's own
    UI. A host with no `launchctl` at all (a Linux cell) is also `None` here; the caller reports the
    gate as INERT rather than pretending it passed or failed.
    """
    # ⛔ WHICH DOMAIN, AND WHY IT MATTERS (review cycle 3, P2). A bare `launchctl list` answers from
    # the CALLER's bootstrap domain: a reaper started by ssh/cron can be in a domain that cannot see
    # the owner's GUI-registered jobs, and a managed daemon that is invisible there reads as
    # "unmanaged" — the fail-OPEN direction on the one gate that protects the owner's own UI. So the
    # caller's GUI domain (where those jobs live) is asked FIRST and by name, and a failed read is
    # INCONCLUSIVE — there is deliberately no fallback (see the block below).
    # ⛔ NO FALLBACK TO A READ THAT THIS FILE ITSELF DECLARES INCOMPLETE (review cycle 5, P1). An
    # earlier revision fell back to a bare `launchctl list` when `gui/<uid>` failed — but the bare
    # read is exactly the one that cannot see the owner's GUI jobs from an ssh/cron domain, so the
    # fallback RE-CREATED the fail-open it was added to close. If the GUI-domain read fails or is
    # empty, gate 4 is INCONCLUSIVE (⇒ report-only, exit 3). A host where this is permanently
    # unreadable (a headless Mac with no GUI session) therefore reaps nothing — which is the correct
    # trade for the gate that protects the owner's own UI.
    try:
        r = subprocess.run([LAUNCHCTL_BIN, "list", f"gui/{os.getuid()}"],
                           capture_output=True, text=True, timeout=LAUNCHCTL_BUDGET_S)
    except Exception:
        return None
    if r.returncode != 0 or not r.stdout.strip():
        return None
    pids: set[str] = set()
    for ln in r.stdout.splitlines():
        # ⛔ DO NOT SKIP LINE 1 AS A HEADER (review cycle 9, P3): a piped `launchctl list` may not
        # emit one, and skipping it would drop the first job — a gate-4 fail-open. A row is a row
        # when its FIRST column is a pid; the header's is "PID", the status-only rows' is "-".
        f = ln.split()
        if f and f[0].isdigit():
            pids.add(f[0])
    if not pids:
        # rc=0 WITH NO PID ROWS IS AMBIGUOUS (review cycle 2, P3): either this domain really has no
        # jobs, or the read answered from a domain that cannot see the caller's jobs (ssh/cron see
        # only the background domain). "Nothing is registered" is the fail-OPEN reading, so an empty
        # parse is INCONCLUSIVE like any other unreadable answer.
        return None
    return pids


def launchd_available() -> bool:
    """Is `launchctl` a thing on this host at all? (a Linux cell has no such probe)"""
    if os.path.sep in LAUNCHCTL_BIN:
        return os.path.exists(LAUNCHCTL_BIN)
    from shutil import which
    return which(LAUNCHCTL_BIN) is not None


DAEMONISH = re.compile(r"--loop|--daemon|--serve|--watch|--interval|--port|--listen|"
                       r"\bserve\b|\.pid\b", re.I)
# A work-item reference in argv or cwd: `#1244`, a PR/issue URL, or the branch-shaped directory a
# lane's checkout is named after — `fix/1244-slug` (a branch) and `fix-1244-slug` (a worktree dir
# derived from one) are both recognised.
REFERENCE = re.compile(r"(?:^|[\s(])#\d{2,}\b|/pull/\d+|/issues/\d+"
                       r"|\b(?:fix|feat|chore)[/-]\d+-")


@dataclass
class Probe:
    """One `lsof -p` read, decomposed. `unreadable` ⇒ the gates that need it are INCONCLUSIVE."""
    cwd: str = ""
    recent_write: str = ""
    listener: str = ""
    transcript: str = ""
    unreadable: str = ""


def open_files(pid: str) -> Probe:
    try:
        r = subprocess.run([LSOF_BIN, "-p", str(pid)], capture_output=True, text=True, timeout=10)
    except Exception as e:
        return Probe(unreadable=f"lsof unavailable ({type(e).__name__})")
    if r.returncode not in (0, 1):      # 1 = lsof found nothing for this pid (it may be gone)
        return Probe(unreadable=f"lsof rc={r.returncode}")
    p = Probe()
    for ln in r.stdout.splitlines()[1:]:
        f = ln.split(None, 8)
        if len(f) < 9:
            continue
        # ⛔ THE COLUMNS ARE `COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME` (review cycle 6,
        # P2). `cwd` is an FD value (field 3), not a TYPE; and a TCP listener's TYPE is `IPv4`/
        # `IPv6`, never the string "socket". Reading the TYPE column as the kind made BOTH the cwd
        # arm and every TCP listener arm dead code — two fail-open holes in the gates that exist to
        # stop a reap, invisible to a suite whose only socket fixture was `unix`.
        fd, typ, name = f[3], f[4], f[8]
        is_socket = (typ.lower() in ("unix", "ipv4", "ipv6", "udp", "udpv4", "udpv6",
                                    "sock", "sockstream", "sockdgram")
                     or "(listen)" in name.lower())
        if fd == "cwd" and name.startswith("/"):
            p.cwd = p.cwd or name
        elif is_socket and not p.listener:
            # FAIL CLOSED: a process holding a listening socket may have a live client, and the
            # NAME field for a listening unix socket is often EMPTY, so an lsof-by-name lookup
            # cannot be trusted to find the client. Holding a listener is therefore reported as
            # DESIGNED, not reaped — see the note above TESTISH.
            p.listener = f"{typ} {name[:40]}".strip()
        elif typ in ("REG", "DIR") and name.startswith("/"):
            if name.endswith(".jsonl") and "/.pi/agent/sessions/" in name and not p.transcript:
                p.transcript = name
            if not p.recent_write:
                try:
                    if time.time() - os.stat(name).st_mtime < RECENT_WRITE_S:
                        p.recent_write = name
                except Exception:
                    pass
    return p


def designed_daemon(pid: str, args: str, probe: Probe) -> str | None:
    """Gate 5. Returns the evidence, or None. Intent leaves traces; an orphan does not."""
    if DAEMONISH.search(args):
        return "DESIGNED — daemon-ish argv"
    state = os.path.join(os.path.expanduser("~"), ".pi", "agent", "state")
    try:
        for f in os.listdir(state):
            if f.endswith(".pid"):
                try:
                    with open(os.path.join(state, f)) as fh:
                        if fh.read().strip() == str(pid):
                            return f"DESIGNED — pidfile {f}"
                except Exception:
                    pass
    except Exception:
        pass
    if probe.unreadable:
        # Named INCONCLUSIVE, not DESIGNED: the refusal is the same (never reap), but requirement 6
        # says the report must say WHICH gate was inconclusive, and a mislabelled refusal reads as a
        # positive finding to the next reader (fresh-context review, note).
        return f"INCONCLUSIVE — open files unreadable ({probe.unreadable})"
    if probe.listener:
        return f"DESIGNED — holds a listening socket ({probe.listener})"
    if probe.recent_write:
        return f"DESIGNED — output written <{int(RECENT_WRITE_S // 60)}min ago: {probe.recent_write[:44]}"
    return None


def diagnostic_value(args: str, probe: Probe) -> str | None:
    """Gate 6 (REAPABLE != RIGHT TO REAP). Returns the evidence, or None.

    A candidate carrying diagnostic value is REPORTED, never killed: a lane's only remaining
    witness is worth more than the core it holds. Whether a named issue is still OPEN needs a `gh`
    read this tool must not pay on a loaded box, so a reference alone is enough to refuse.
    """
    if probe.unreadable:
        return f"INCONCLUSIVE — open files unreadable ({probe.unreadable})"
    if probe.transcript:
        return f"holds a lane transcript: {probe.transcript[:60]}"
    m = REFERENCE.search(args) or REFERENCE.search(probe.cwd)
    if m:
        return f"names a work item ({m.group(0).strip()}) in argv/cwd — its state was not read"
    if probe.recent_write:
        return f"wrote a file <{int(RECENT_WRITE_S // 60)}min ago: {probe.recent_write[:60]}"
    return None


@dataclass(frozen=True)
class Ancestry:
    """The FULL parent chain, or an explicit statement that it could not be read."""
    path: tuple[str, ...]
    verdict: str            # "HUMAN:<what>" | "NO-HUMAN" | "INCONCLUSIVE"
    detail: str


def ancestry(pid: str, rows: dict[str, dict], depth: int = 25) -> Ancestry:
    """Gate 2. Walk the parent chain TO THE TOP, then decide OWNERSHIP POSITIVELY.

    ⛔ `ppid 1` is not evidence of orphanhood (a service daemonises to 1 by design, and a Linux
    subreaper adopts orphans so their ppid is the subreaper). The WALK is the gate, and a walk that
    cannot reach the top is INCONCLUSIVE — the previous implementation recorded an unknown hop in
    the path and then read the absence of a human match as "no human", i.e. it failed OPEN on
    exactly the case README §6.5.3 forbids.

    ⛔ AND "NO HUMAN MARKER FOUND" IS NOT "OWNERLESS" (review cycle 7, P2). A deny-list of host
    applications can only ever refuse the hosts someone thought of: a human's parked `pytest`
    started from a GUI/IDE test runner (VS Code/Electron, PyCharm, Xcode) has NO pty and NO shell in
    its chain, so it walked as NO-HUMAN and was reapable — the same near-miss shape #1244 exists to
    prevent, via a host not in the table. So the verdict is now POSITIVE: a candidate may only be
    NO-HUMAN when its chain is `[candidate, <launchd/init>]` exactly — nothing in between to
    classify and no tty of its own. Any intermediate ancestor that is not a recognised human is
    INCONCLUSIVE ("we cannot say who owns this"), never a pass. The marker table is kept because a
    named human is a BETTER message than "unknown", not because it is the whole test.
    """
    hops: list[dict] = []
    cur, seen = str(pid), set()
    truncated = ""
    while True:
        if not cur or cur == "0":
            break
        if cur in seen or len(seen) >= depth:
            truncated = f"cycle or depth limit ({depth}) reached at pid {cur}"
            break
        seen.add(cur)
        r = rows.get(cur)
        if r is None:
            truncated = f"pid {cur} is not visible in the process table — chain unreadable"
            break
        hops.append(r)
        cur = r["ppid"]

    path = tuple(f"{h['pid']}:{h['comm']}" for h in hops)
    if truncated:
        return Ancestry(path, "INCONCLUSIVE", truncated)

    # 1. a NAMED human anywhere above the candidate (the better message)
    for r in hops[1:]:
        hay = f"{r['comm']} {r['args']}"
        for pat in (HUMAN_PATH, HUMAN_WORD):
            m = pat.search(hay)
            if m:
                return Ancestry(path, f"HUMAN:{m.group(0)}",
                                f"ancestor pid {r['pid']} is {m.group(0)}")
    # 2. an interactive shell owned by this uid (login shell, or any shell holding a tty)
    for r in hops:
        base = os.path.basename(r["comm"].split(" (")[0])
        login_shell = base.startswith("-")
        interactive = login_shell or not NO_TTY.match(r["tty"])
        if base in SHELLS and r["uid"] == str(os.getuid()) and interactive:
            return Ancestry(path, f"HUMAN:shell:{base}",
                            f"pid {r['pid']} is an interactive shell ({base}, tty {r['tty']}) "
                            f"owned by uid {r['uid']}")
    # 3. an intermediate ancestor we cannot classify: ownership unproven
    intermediate = hops[1:-1]
    if intermediate:
        a = intermediate[0]
        return Ancestry(path, "INCONCLUSIVE",
                        f"ancestor pid {a['pid']} ({a['comm'][:40]}) is not classified — the chain "
                        f"cannot prove this process is ownerless")
    # 4. the candidate's own tty: a session it belongs to is not walkable from a reparented chain
    if not NO_TTY.match(hops[0]["tty"]):
        return Ancestry(path, "INCONCLUSIVE",
                        f"the candidate owns a tty ({hops[0]['tty']}) — the session it belongs to is "
                        f"not walkable from a reparented chain")
    return Ancestry(path, "NO-HUMAN", "chain is exactly [candidate, launchd/init] and owns no tty")


def class_of(args: str) -> ProcClass | None:
    for k in PROC_CLASSES:
        if re.search(k.pattern, args, re.I):
            return k
    return None


@dataclass(frozen=True)
class Distribution:
    verdict: str        # "OVERLONG" | "plausible" | "INCONCLUSIVE"
    detail: str


def distribution(klass: ProcClass | None, age_s: float) -> Distribution:
    """Gate 3. Age against the class's OWN slow tail — read from data, never from an if-statement."""
    if klass is None:
        return Distribution("INCONCLUSIVE",
                            "no class matched argv, so this process has no expected distribution "
                            "to be measured against")
    if klass.expected_s is None:
        return Distribution("INCONCLUSIVE",
                            f"{klass.name} has NO measured distribution ({klass.source}) — a class "
                            "without data cannot be declared past it")
    limit = max(klass.floor_s, klass.expected_s * klass.overlong_x)
    ratio = age_s / klass.expected_s if klass.expected_s else float("inf")
    detail = (f"{age_s / 3600:.2f}h vs {klass.name} slow tail {klass.expected_s / 60:.0f}m "
              f"= {ratio:.1f}x (limit {klass.overlong_x:.1f}x = {limit / 3600:.2f}h; source: "
              f"{klass.source})")
    return Distribution("OVERLONG" if age_s > limit else "plausible", detail)


@dataclass
class Decision:
    pid: str
    comm: str
    args: str
    klass: str
    age_s: float
    cpu_delta_s: float
    gates: dict[str, str] = field(default_factory=dict)
    ancestry_path: tuple[str, ...] = ()
    ancestry_verdict: str = ""
    verdict: str = "REPORT"
    reason: str = ""
    ident: tuple[str, str, float] = ("", "", 0.0)

    @property
    def age(self) -> str:
        if self.age_s < 0:
            return "age-unknown"
        total = int(self.age_s)
        h, rem = divmod(total, 3600)
        m = rem // 60
        return f"{h}h{m:02d}m" if h else f"{m}m"


def decide(pid: str, before: dict, table: dict[str, dict],
           after: dict, reg: set[str] | None, window: float = WINDOW_S) -> Decision | None:
    """One candidate → one Decision. Returns None when the pid exited during the sample."""
    now = after.get(pid)
    if now is None:
        return None
    t_before, t_after = cpu_seconds(before["time"]), cpu_seconds(now["time"])
    # ⛔ AN UNPARSEABLE READING IS NOT A ZERO DELTA (fresh-context review, P3): -1.0 − -1.0 = 0.0
    # would read as PARKED, i.e. gate 1 would fail OPEN on exactly the reading it could not make.
    delta = -1.0 if (t_before < 0 or t_after < 0) else t_after - t_before
    age_s = etime_seconds(before["etime"])
    klass = class_of(before["args"])
    d = Decision(pid=pid, comm=before["comm"], args=before["args"],
                 klass=klass.name if klass else "UNKNOWN", age_s=age_s, cpu_delta_s=delta,
                 ident=(before["comm"], before["args"], etime_seconds(before["etime"])))

    # ── gate 1: parked over the stated window ───────────────────────────────────────────────
    if delta < 0:
        parked, d.gates["1_cpu"] = False, f"INCONCLUSIVE — cpu time went backwards ({delta:+.2f}s)"
    else:
        parked = 0.0 <= delta < TOLERANCE_S
        d.gates["1_cpu"] = (f"PARKED {delta:+.2f}s < {TOLERANCE_S:.2f}s" if parked
                            else f"ALIVE {delta:+.2f}s >= {TOLERANCE_S:.2f}s")

    # ── gate 2: ancestry walk to the top ───────────────────────────────────────────────────
    anc = ancestry(pid, table)
    d.ancestry_path, d.ancestry_verdict = anc.path, anc.verdict
    d.gates["2_ancestry"] = f"{anc.verdict} — {anc.detail}"

    # ── gate 3: own expected distribution ──────────────────────────────────────────────────
    if age_s < 0:
        # An unreadable `etime` is not a young process (review cycle 2, P3).
        dist = Distribution("INCONCLUSIVE", "elapsed time (etime) is not parseable — age unknown")
    else:
        dist = distribution(klass, age_s)
    d.gates["3_expected"] = f"{dist.verdict} — {dist.detail}"

    probe = open_files(pid)

    # ── gate 4: launchd registration ───────────────────────────────────────────────────────
    if reg is None and not launchd_available():
        d.gates["4_launchd"] = "INAPPLICABLE — no `launchctl` on this host (a Linux cell)"
    elif reg is None:
        d.gates["4_launchd"] = "INCONCLUSIVE — `launchctl` could not be read"
    elif pid in reg:
        d.gates["4_launchd"] = "REGISTERED — a managed job with an owner (never reap)"
    else:
        d.gates["4_launchd"] = "unmanaged"

    # ── gate 5: designed daemon ────────────────────────────────────────────────────────────
    designed = designed_daemon(pid, before["args"], probe)
    d.gates["5_designed"] = designed or "no daemon trace"

    # ── gate 6: diagnostic value ───────────────────────────────────────────────────────────
    diagnostic = diagnostic_value(before["args"], probe)
    d.gates["6_diagnostic"] = diagnostic or "none"

    # ── the decision, IN ORDER: the first failing gate is the reason ───────────────────────
    if delta < 0:
        d.reason = "gate 1 inconclusive (a CPU read that went backwards cannot say PARKED)"
    elif not parked:
        d.reason = f"gate 1: not parked ({delta:+.2f}s over {window:.1f}s)"
    elif anc.verdict != "NO-HUMAN":
        # HUMAN:x refuses a human's process; INCONCLUSIVE refuses because the walk was blind.
        d.reason = f"gate 2: {anc.verdict} — {anc.detail}"
    elif dist.verdict != "OVERLONG":
        d.reason = f"gate 3: {dist.verdict} — {dist.detail}"
    elif reg is None and not launchd_available():
        d.reason = ("gate 4: INAPPLICABLE — no `launchctl` on this host, so a launchd-managed job "
                    "cannot be ruled out")
    elif reg is None:
        d.reason = ("gate 4: INCONCLUSIVE — `launchctl` could not be read, so a managed job "
                    "cannot be ruled out")
    elif pid in reg:
        d.reason = "gate 4: registered launchd job — a managed daemon has an owner"
    elif diagnostic:
        # gate 6 BEFORE gate 5: a recent write IS diagnostic value, and attributing it to gate 5
        # made the report say "designed daemon" for a process nobody claimed was one (cycle 7, P3).
        d.reason = f"gate 6: DIAGNOSTIC ({diagnostic}) — reported, never killed"
    elif designed:
        d.reason = f"gate 5: {designed}"
    else:
        d.verdict, d.reason = "REAP", "all gates passed"
    return d


def still_same(d: Decision, table: dict[str, dict]) -> tuple[bool, str]:
    """Is `d.pid` STILL the process we decided about? (the kill-by-stale-pid guard)

    ⛔ SIGNALLING BY PID ALONE IS UNSAFE (fresh-context review, P2). Between the decision snapshot
    and the signal — and again between SIGTERM and SIGKILL — the pid can be REUSED on a box that
    churns processes, and a `SIGKILL` then lands on an unrelated same-uid process, potentially a
    freshly spawned lane worker. So every signal is preceded by a fresh read whose identity is
    compared: comm AND argv must match, and elapsed time must not go backwards (a reused pid has a
    younger etime). Anything unverifiable is a SUPPRESSION, never a signal.
    """
    row = table.get(d.pid)
    if row is None:
        return False, "gone"
    if (row["comm"], row["args"]) != (d.ident[0], d.ident[1]):
        return False, (f"pid REUSED — comm/argv changed ({row['comm'][:40]!r} is not "
                       f"{d.ident[0][:40]!r})")
    if etime_seconds(row["etime"]) + 1.0 < d.ident[2]:
        return False, (f"pid REUSED — elapsed time went backwards "
                       f"({row['etime']} < {d.ident[2]:.0f}s): a different process holds this pid")
    return True, "same process"


def cpu_header(window: float) -> str:
    """The gate-1 line. Formatted FROM the constants, so the report cannot drift from the decision."""
    return (f"CPU: window={window:.1f}s tolerance={TOLERANCE_S:.2f}s "
            f"(PARKED = 0.00s <= delta < {TOLERANCE_S:.2f}s; floor MIN_WINDOW_S={MIN_WINDOW_S:.1f}s)")


def log_decision(mode: str, window: float, d: Decision, population: str = "owner") -> None:
    rec = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "mode": mode, "population": population, "pid": d.pid, "comm": d.comm, "class": d.klass,
        "age_s": round(d.age_s, 1), "age": d.age,
        "cpu_delta_s": round(d.cpu_delta_s, 2),
        "window_s": window, "tolerance_s": TOLERANCE_S,
        "ancestry": d.ancestry_verdict, "ancestry_path": list(d.ancestry_path),
        "gates": d.gates, "verdict": d.verdict, "reason": d.reason,
    }
    try:
        os.makedirs(os.path.dirname(DECISION_LOG), exist_ok=True)
        with open(DECISION_LOG, "a") as fh:
            fh.write(json.dumps(rec, sort_keys=True) + "\n")
    except Exception as e:
        print(f"  ⚠️ decision log unwritable ({DECISION_LOG}): {e}", file=sys.stderr)


def signal_pid(pid: str, sig: int) -> None:
    """Signals go through KILL_BIN when it is set (a hermetic run), else the real os.kill."""
    if KILL_BIN:
        subprocess.run([KILL_BIN, f"-{sig}", str(pid)], capture_output=True)
        return
    os.kill(int(pid), sig)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="actually SIGTERM (default: dry run)")
    ap.add_argument("--sample", type=float, default=WINDOW_S, help="CPU sample window, seconds")
    ap.add_argument("--include-any-owner", action="store_true",
                    help="do not require the path to be under YOUR Documents/GitHub")
    a = ap.parse_args()

    if os.getuid() == 0:
        # A reaper with root can signal anything on the box, which is not the authority this tool
        # claims ("our own checkouts, this owner"). Fail closed with a usage error (cycle 3, P3).
        print("ERROR: refusing to run as root — this reaper is scoped to the invoking owner's own "
              "processes; running it as root would widen it to every account on the box.",
              file=sys.stderr)
        return 2
    window = a.sample
    if window <= 0:
        print("ERROR: --sample must be > 0", file=sys.stderr)
        return 2
    # ⛔ "KILL_BIN IS SET" IS NOT THE SAME AS "SIGNALLING IS REDIRECTED" (review cycle 5, P3): an
    # operator who exported KILL_BIN=/bin/kill would otherwise unlock a sub-floor window on a box
    # that can still really signal. A shim is a path that is NOT one of the system kill binaries.
    # ⛔ TWO KEYS, NOT ONE HEURISTIC (review cycles 8 and 9, P3). Matching the NAME "kill" let
    # /bin/pkill unlock a sub-floor window; matching a SYSTEM DIRECTORY let /opt/homebrew/bin/kill
    # through. Neither is the property that matters — "this run cannot really signal" is a fact only
    # the caller can assert, so it takes TWO explicit switches: a redirected KILL_BIN *and*
    # ORPHAN_REAP_TEST_SHIM=1. Production sets neither, so no single exported variable can lower the
    # floor on a box that can still signal. (Every test in `orphan_reap.test.py` sets both.)
    kill_shimmed = bool(KILL_BIN) and os.environ.get("ORPHAN_REAP_TEST_SHIM") == "1"
    if window < MIN_WINDOW_S and not kill_shimmed:
        # A spin sampled over 0.2s has had no time to diverge from parked, so a short window
        # turns gate 1's necessity into a false positive. The only runs allowed a short window
        # are ones where signalling is redirected — i.e. ones that cannot cost a process.
        print(f"ERROR: --sample {window:g} < MIN_WINDOW_S {MIN_WINDOW_S:g}; a window that short "
              f"cannot tell a parked process from a spinning one. (Allowed only when KILL_BIN is "
              f"a KILL shim: a hermetic run can signal nothing.)", file=sys.stderr)
        return 2

    try:
        os.makedirs(os.path.dirname(DECISION_LOG), exist_ok=True)
        with open(DECISION_LOG, "a"):
            pass
    except Exception as e:
        # "Every decision is logged" is a safety property, not a nicety: an action nobody can audit
        # must not happen. Unwritable log ⇒ fail closed, nothing signalled (cycle 7, P3).
        print(f"FAIL-CLOSED: the decision log is not writable ({DECISION_LOG}): {e} — nothing "
              f"signalled.", file=sys.stderr)
        return 3

    before = proc_table()
    if before is None:
        print("FAIL-CLOSED: the process table could not be read — nothing signalled, nothing "
              "reported as clean.", file=sys.stderr)
        return 3
    reg = launchd_pids()

    cands = {}
    # A reaper must never be a candidate for itself or ANY of its own ancestors (review cycle 9,
    # P3): a `pytest`-shaped wrapper high in our own chain could otherwise be reaped by the reaper it
    # spawned, cascading into the reaper itself. Walk our own ancestry out of the same table.
    self_pids = {str(os.getpid())}
    walk = str(os.getppid())
    for _ in range(64):
        if not walk or walk == "0" or walk in self_pids:
            break
        self_pids.add(walk)
        row = before.get(walk)
        if row is None:
            break
        walk = row["ppid"]
    foreign = 0
    for pid, r in before.items():
        if pid in self_pids:
            continue
        if r["uid"] != str(os.getuid()):
            # `--include-any-owner` widens the PATH test, not the AUTHORITY: a reaper may never
            # signal another account's process, and its ancestry walk is written from this owner's
            # point of view (cycle 5, P3).
            foreign += 1
            continue
        if not TESTISH.search(r["args"]):
            continue
        if not (OURS.search(r["args"]) or a.include_any_owner):
            continue
        cands[pid] = r

    population = "any-owner" if a.include_any_owner else "owner"
    mode = "apply" if a.apply else "dry-run"
    print(f"mode={mode}  population={population}  {cpu_header(window)}")
    if reg is None:
        why = ("INAPPLICABLE (no launchctl on this host)" if not launchd_available()
               else "INCONCLUSIVE (unreadable)")
        print(f"launchd gate: {why} — every candidate is report-only")
    else:
        print(f"launchd gate: {len(reg)} registered job(s)")
    print(f"decision log: {DECISION_LOG}")
    print(f"candidates (ours, test/tooling-shaped, any depth, uid {os.getuid()}): {len(cands)}"
          + (f"   [{foreign} skipped: another uid]" if foreign else "") + "\n")
    time.sleep(window)
    after = proc_table()
    if after is None:
        print("FAIL-CLOSED: the second process-table read failed — nothing signalled.",
              file=sys.stderr)
        return 3

    reap: list[Decision] = []
    for pid, r in sorted(cands.items(), key=lambda kv: etime_seconds(kv[1]["etime"]), reverse=True):
        d = decide(pid, r, before, after, reg, window)
        if d is None:
            print(f"  {pid}  EXITED during sample — nothing to do")
            continue
        print(f"  {d.pid}  {d.comm}  class={d.klass} age={d.age} ppid={before[d.pid]['ppid']}")
        print(f"        {d.args[:130]}")
        for k, v in d.gates.items():
            print(f"        gate {k:13s} {v}")
        print(f"        => {d.verdict}: {d.reason}\n")
        log_decision(mode, window, d, population)
        if d.verdict == "REAP":
            reap.append(d)

    launchd_unreadable = reg is None and launchd_available()
    print(f"==== {len(reap)} reapable · {len(cands) - len(reap)} report-only ====")
    if launchd_unreadable:
        print("FAIL-CLOSED: `launchctl` exists but could not be read, so gate 4 could not be "
              "evaluated for any candidate — nothing was signalled and this is exit 3.",
              file=sys.stderr)
    if not a.apply:
        print("dry run — nothing signalled. Re-run with --apply to SIGTERM the reapable set.")
        return 3 if launchd_unreadable else 0

    signalled: list[Decision] = []
    for d in reap:
        # A FRESH read, identity-checked, immediately before the signal — the decision snapshot may
        # be minutes old by now (each candidate costs an lsof), and a pid is not an identity.
        fresh = proc_table()
        if fresh is None:
            print("FAIL-CLOSED: the pre-signal read failed — NOTHING further was signalled.",
                  file=sys.stderr)
            return 3
        ok, why = still_same(d, fresh)
        if not ok:
            print(f"  SUPPRESS {d.pid} ({d.comm}): {why} — no signal sent")
            d.verdict, d.reason = "SUPPRESSED", f"pre-signal re-verify: {why}"
            log_decision(mode, window, d, population)
            continue
        try:
            signal_pid(d.pid, 15)
            signalled.append(d)
            print(f"  SIGTERM -> {d.pid} ({d.comm})")
            d.verdict, d.reason = "SIGNALLED", "SIGTERM sent after all gates passed"
            log_decision(mode, window, d, population)
        except ProcessLookupError:
            print(f"  {d.pid} already gone")
        except PermissionError:
            print(f"  {d.pid} EPERM — not ours to kill; REPORTING")
            d.verdict, d.reason = "EPERM", "signal refused by the kernel (not this uid's process)"
            log_decision(mode, window, d, population)
    time.sleep(SETTLE_S)
    # ⛔ A FRESH READ PER SURVIVOR, NOT ONE SHARED SNAPSHOT (fresh-context review cycle 4, P2). The
    # header promises that EVERY signal is preceded by a fresh identity check; a single `still`
    # snapshot read before the loop let a pid that died inside the window be reused by a same-uid
    # process with identical comm+argv, and the SIGKILL then landed on the newcomer.
    for d in signalled:
        fresh = proc_table()
        if fresh is None:
            print("FAIL-CLOSED: the post-signal read failed — survivors CANNOT be verified.",
                  file=sys.stderr)
            return 3
        ok, why = still_same(d, fresh)
        if ok:
            try:
                signal_pid(d.pid, 9)
                print(f"  SIGKILL -> {d.pid} (did not exit on TERM)")
                d.verdict, d.reason = "SIGKILLED", "survived SIGTERM inside the grace window"
                log_decision(mode, window, d, population)
            except Exception as e:
                print(f"  {d.pid} still alive, kill failed: {e}")
        elif why == "gone":
            print(f"  verified gone: {d.pid}")
        else:
            print(f"  SUPPRESS SIGKILL {d.pid}: {why} — the survivor is a DIFFERENT process")
    return 3 if launchd_unreadable else 0


if __name__ == "__main__":
    sys.exit(main())
