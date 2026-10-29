#!/usr/bin/env python3
"""orphan-reap.py — reap ORPHANED test/tooling processes, under the five gates.

WHY THIS EXISTS
`orphan-scan.py` only reports (and is pinned to one lane's needle); `embedded_orphans.py` is a
census; `run_reaper.py` cancels GitHub Actions runs, not processes. So the class that #5035
documented — a test process whose parent died, silently promoted to `ppid 1` where **nothing owns
it**, free to run for two days — had NO reaper. The three-gate walk that killed the 43h48m pytest
was done **by hand**. This is that walk, as code, with the dry-run as the default.

    #5035's own words: "`ppid 1` is a silent promotion to 'nobody owns this.'"

THE FIVE GATES (all must pass; any unclear read => REPORT, never reap)
  1. CPU DELTA, tolerance stated — a sub-0.1 s twitch has the same signature as a parked fork
     child, a human's prompt redraw, or a timer wake. So: PARKED = delta < 0.10 s over the
     sample. (A spin, by contrast, is 100x that: #5035 measured +19.44 s over 30 s.)
  2. ANCESTRY WALK TO THE TOP — any Terminal.app / iTerm / login-shell ancestor means it belongs
     to a HUMAN: never touch it, however parked it looks. `ppid 1` alone proves nothing (a
     daemonising service reparents to 1 BY DESIGN), which is why the walk is the gate.
  3. ITS OWN EXPECTED DISTRIBUTION — progress judged against what this class of process should
     cost, not against the clock in general.
  4. ⛔ LAUNCHD-REGISTRATION GATE (added 2026-10-12) — if the pid is a REGISTERED launchd job,
     it is a managed daemon with an owner (the owner's menu-bar app, minutes-mcp, cmux...).
     `ppid 1` looks identical. NEVER reap one. Without this gate the reaper kills the owner's
     own UI.
  5. ⛔ DESIGNED-DAEMON GATE (added 2026-10-12, AFTER THE FIRST DRY RUN WAS WRONG) — gates 1-4
     passed on THREE processes and ALL THREE were wrong to reap:
       * `live-workspaces-publisher.py` — `--loop` in argv, a pidfile, and its output file
         written 10 minutes ago. A LIVE daemon that merely got reparented, not an orphan;
       * two `redis-server` processes whose unix sockets had a LIVE CLIENT (`lsof` showed a
         second holder on each) — reaping them would have broken a running test.
     Intent is not visible in `ppid`, CPU, or elapsed time. So: pidfile naming the pid, a
     daemon-ish flag in argv, an output file touched recently, or ANY live holder of a socket
     it owns  =>  DESIGNED => never reap.

Reapable != right to reap: a candidate with diagnostic value stays (evidence beats tidiness).

THE `pi` POOL (added 2026-10-22) — WHY IT IS THE SAME REAPER
----------------------------------------------------------------
The `ppid=1 + our-checkout + testish` population above CANNOT SEE A `pi` LANE: a lane's `pi`
reparents to `launchd` (or sits under tmux/cmux), its argv is the bare word `pi`, and nothing
about it matches TESTISH. So the session pool had **no owner at all** and grew without bound —
measured 2026-10-22T14:25Z on the hub: 64 `pi`, 21 of them 1-9 days old with up to 24,000 s of CPU
burned earlier and a 0.00 s delta over 20 s. This file is where that pool gets its owner, because
writing a second reaper is how two contracts for one rule appear (#1178).

⛔ IT CONSUMES THE ONE LIVENESS VERDICT, IT DOES NOT RE-DERIVE IT. The kill authorisation is
`tools/fleet/liveness.py::evaluate` returning `idle` (JSONL age past the retirement proof,
`IDLE_MS` 24 h) — the same predicate `lane_liveness.py` schedules and `pi-reap-idle.sh` obeys.
The verdict is obtained from `liveness.gather()` — the canon's OWN acquisition, so the cmux hook
store is read and its vetoes are live: a lane whose record says it consumed input inside
`RECORD_VETO_MS` is `running-quiet` (#947), and an UNREADABLE store abstains (`store-unreadable`)
rather than being assumed empty. This file adds exactly ONE candidate: the live pid it is already
holding from a fresh `ps` read (the canon's C2 direction — a live writer with no usable record is
a candidate — admits it, and `collect_candidates` cannot see a bare-argv `pi`).
The direction is the difference, and it is deliberate: `gather()` starts from a STORE RECORD and
fences a pid to it; here we start from a live pid and derive its session — so the identity question
is "which session does this process own?" (below). If `evaluate` says anything but `idle` —
including every abstention — this reaper does not act.

THE FOUR STATES (never collapsed; printed as columns and as counts)
    LIVE             progress is being made, by ANY channel (growth beats CPU)
    PARKED-REAPABLE  all three gates pass AND the canon verdict is `idle`
    KEEP-HUMAN       a terminal/login-shell ancestor: belongs to a human, never touched
    UNVERIFIABLE     an ABSTENTION: no action, and never rendered as "nothing to reap"

THE THREE GATES, EACH WITH ITS STATED TOLERANCE
  1. CPU DELTA — cumulative `ps -o time=` sampled TWICE, window printed with the census.
     PARKED = delta < 0.10 s. The tolerance is named because a sub-0.1 s twitch has the SAME
     signature from a parked fork child, a prompt redraw and a timer wake, so it may not be
     implied by silence. (A spin is 100x that: #5035 measured +19.44 s over 30 s.)
  2. ANCESTRY TO THE TOP — any Terminal.app / iTerm / login-shell / tmux / cmux.app ancestor
     means HUMAN: never touch, however parked. `ppid 1` alone proves nothing (daemons reparent
     to 1 by design), which is why the walk — not the parent's identity — is the gate.
  3. ITS OWN EXPECTED DISTRIBUTION — progress judged against what THIS process's own session
     normally does, never against the clock in general. The expected interval is the median
     inter-entry gap of its own transcript tail; STOPPED requires age >= max(IDLE_MS (24 h, the
     canon's retirement proof), 100 x that gap) — two orders out. ⚠️ The floor DOMINATES in
     practice: the bound can never fall below `IDLE_MS`, so a 5-hour-frozen transcript is NOT
     stopped (it is `LIVE`/inside the canon's retirement window) — gate 3 can only make the
     canon's own bound STRICTER, never looser. A transcript that GREW inside the window is LIVE
     and the CPU reading never overrides it. An unreadable stat is an ABSTENTION, never
     `age < bound`.

BINDING A PID TO ITS SESSION (the evidence gate 3 needs)
    ONE RUNG, ON PURPOSE: the session file whose name-stamp (UTC, ms) is within FENCE_S of the
    process start (`now - etime`), UNIQUE inside that fence. `FENCE_S` is READ FROM THE CANON
    (`FENCE_TOLERANCE_SECONDS`, default 3 s, `scripts/lib/pid-identity.sh:68`) — not restated here,
    because a different bound is a second identity rule the canon cannot see (§3 of
    `docs/ops/fleet-liveness.md`). Measured on one cell: 11 of 14 live `pi` matched within 0.5 s.
    An argv `--session <sid>` form is NOT parsed here: which session a pid claims is
    `pid-identity.sh`'s `probe-argv` / `argv-candidates` question, and a local regex would be
    narrower than the rule it imitates (it would miss `-r` / `--resume`). Consequence, stated: a
    RESUMED session keeps its original name-stamp, misses the fence, and abstains as
    `no-session-file`.

DECLARED BLIND SPOTS (a report must say what it CANNOT see — `lane-status.py`'s own header:
"it cannot see a lane that leaves none"). This reaper cannot see:
  * a `pi` whose session file it cannot bind (`no-session-file`) — a `task`/print-mode child runs
    with sessions disabled, and a resumed session keeps its original stamp;
  * a `pi` that SWITCHED session inside its own lifetime (`/new`, `/fork`, `/clone`) — pi writes a
    FRESH stamped file for the new session and leaves the old one on disk, so the fence binds the
    ABANDONED file (it matches the start stamp exactly and is usually the only match) and gate 3
    ages the dead transcript. The row can then read `PARKED-REAPABLE` for a lane that was writing
    seconds ago. Nothing is signalled under the shipped default — a hostless chain is masked by
    the host decision — but the CENSUS's evidence is wrong for that row, and the reopening seam is
    exactly where it would become a wrong kill. Named here rather than left to be discovered; the
    fix needs an identity source this fence does not have (the argv sid, or the file the process
    holds open), i.e. a canon question: #2475;
  * a `pi` started inside another's fence in the same cwd (`ambiguous-binding`);
  * any process of another uid — but NOT by abstaining: `_cwd_of_pid` returns None on a refused
    read and `bind_session` then SKIPS the cwd filter, so such a pid can still bind a
    same-fence session file and vote on it. `binding_detail` records that the pid side went
    UNCHECKED, so the row shows it; and the FILE side of the same filter IS fail-closed: a session
    file whose own first lines carry no readable `cwd` is dropped from the candidates, never
    accepted for any pid — including when the pid's own `cwd` could not be read, which is the case
    that matters, since the pid side is then skipped entirely;
  * a box where the cmux hook store is unreadable — every row that reaches the canon abstains as
    `store-unreadable` (the canon's own rule), but a row under a terminal/login-shell ancestor is
    decided `KEEP-HUMAN` by gate 2 BEFORE the canon VERDICT is consulted (the canon is still
    read; gate 2 supersedes its answer) and so does not abstain. The
    safe property (nothing reaped) holds; the count is not "every row";
  * memory pressure, fd pressure, or a live child of a parked parent it does not enumerate;
  * an interactive host missing from `HUMAN` (WezTerm/Ghostty/Zed are covered; VS Code's
    `Code Helper` CANNOT be matched — `ps -Ao comm=` is space-split, so a helper name containing a
    space never matches any entry, and a VS Code session is caught only through its shell /
    terminal ancestor, or not at all if that ancestor is a bare `-sh`). The list is an allowlist of
    owners, so a new host is a real gap.
⛔ A blind spot is NOT uniformly an abstention. Where the census cannot decide, it is reported as
UNVERIFIABLE with its reason. But one bullet above does not abstain: an unreadable cwd means
`bind_session` skips the pid-side filter, so the row can bind, speak, and be scored LIVE on the
fence evidence alone — while the FILE side stays fail-closed (a `cwd`-less transcript is never a
candidate) and `binding_detail` records that the pid-side cwd went unchecked, so the row shows it.
The store-unreadable bullet does not abstain either: such a row under a terminal ancestor is
`KEEP-HUMAN` from gate 2 before the canon's verdict is consulted.

USAGE
    orphan-reap.py                 # dry run (default): report every candidate + gate reading
    orphan-reap.py --pool pi       # the `pi` session pool (four states); dry run by default
    orphan-reap.py --pool all
    orphan-reap.py --apply         # the ORPHAN pool: SIGTERM, then SIGKILL 3 s later, then verify
    orphan-reap.py --pool pi --apply   # SIGTERM only PARKED-REAPABLE, gate 2 + the authorisation
                                   # re-checked live; this pool NEVER escalates to SIGKILL, and
                                   # exits 1 when a signalled target survives. The scoping matters:
                                   # the unqualified `--apply` on the line above DOES SIGKILL, and
                                   # its orphan path predates the pi pool's re-verification (#2410).
    orphan-reap.py --sample 20     # CPU sample window in seconds (default 15)
    orphan-reap.py --json          # machine-readable census

TESTS: `python3 scripts/orphan-reap.test.py` (+ `--mutations`: each gate dropped must go RED).
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

# ── the candidate class ───────────────────────────────────────────────────────────────────────
# Only things WE run inside our own checkouts. An Apple executable is never a candidate, and a
# launchd job is never a candidate (gate 4). Both exclusions are positive identification, so a
# new Apple helper that happens to sit at ppid 1 is reported-not-reaped rather than killed.
OURS = re.compile(r"^/Users/[^/]+/Documents/GitHub/")
TESTISH = re.compile(r"pytest|^\.?/?.+\.venv/bin/python|uvicorn|gunicorn|/bin/bash -c ", re.I)
# ⛔ NOT IN THIS TOOL'S CLASS: embedded `redislite` redis-server processes. Another agent owner
# already exists for them — `tortoise/tools/embedded_orphans.py` (the bounded census), the launchd
# job `com.tortoise.embedded-reaper`, and issue #3599 — whose only_safe mode exists precisely
# because a stranded redis CAN still have a live client. Reaping them here would duplicate that
# logic and, measured 2026-10-12, would have broken a running test: `lsof` showed pid 72824 holding
# the socket of BOTH stranded servers. Leave them to their owner; do not widen this regex.
# A human's terminal — the ancestry gate. Checked as a SUBSTRING of the full ancestor path.
# ⛔ THE LIST IS AN ALLOWLIST OF OWNERS, so a missing host is a human's parked prompt read as a
# candidate. It is therefore deliberately BROAD: WezTerm/Ghostty/Zed/Tabby/Hyper, plus `-zsh` /
# `-bash` / `sshd` for an interactive login whose shell is not `/usr/bin/login`.
# ⛔ AND IT CANNOT NAME A MULTI-WORD HELPER. `ps -Ao comm=` gives ONE field per row and the parser
# splits with `split(None, 6)`, so a helper whose executable name contains a space ("Code Helper")
# arrives truncated at the space and no entry containing a space can ever match. Entries are
# therefore SPACE-FREE by rule; VS Code's helper is a declared, un-matched gap (a human's VS Code
# session is caught only through its shell / terminal ancestor).
HUMAN = ("Terminal.app", "iTerm", "/usr/bin/login", "login.app", "Warp.app", "kitty.app",
         "Alacritty.app", "cmux.app", "tmux", "WezTerm", "Ghostty", "Zed", "Tabby", "Hyper",
         "sshd", "-zsh", "-bash")
assert not [h for h in HUMAN if " " in h], "a HUMAN entry with a space can never match (see above)"

# ── GATE 2's HOST DECISION — the RECORDED RULE, in ONE place ──────────────────────────────────
# Gate 2's job is not "did any string in the walk look like a terminal"; it is to CLASSIFY the
# chain so that only an authorised class can be signalled. The rule is #1207's, as the owner
# approved it on #1297 ("option A"):
#     human terminal / login-shell anywhere on the walk -> KEEP-HUMAN (never signal)
#     a cmux node                                       -> report-only
#     unrecognised / unresolvable / empty                -> unknown: REPORT ONLY, NEVER REAP
# ⚠️ THE `cmux` CLASS HAS NO BRANCH OF ITS OWN, and this comment must not be read as if it had one.
# `cmux.app` is a `HUMAN` entry, so a chain under it returns kind `human` (never signalled — the
# SAFE outcome) but the census LABELS it KEEP-HUMAN, "belongs to a human", which is not the
# recorded rule's distinct report-only class; a bare `cmux` node (no `.app` bundle component)
# matches nothing and falls to `hostless`. Both refuse to signal, so this is a census-accuracy
# defect, not a kill path. Collapsing the two classes is recorded as a follow-up rather than
# fixed here; if a `cmux` kind is ever added, it must stay report-only.
# #1207 states the literal clause this file had ignored: "Unknown/unparseable chain ⇒ report
# only, never reap." TWO shapes are `unknown` here, and both must abstain:
#   * `ancestry()` hit a hop missing from the snapshot -> `<pid N not visible>`;
#   * the walk resolved but carries NO host app at all (a `pi` reparented to launchd — which is
#     exactly this pool's target population, so the human-only test is structurally inert for it).
# A chain that could not be resolved must never read as a clean one.
#
# ⛔ `AUTHORISE_HOSTLESS_CHAINS` is the ONE reopen seam, and it is False. Shipping it True would
# reverse owner-approved option A for a population that decision never saw (a lane `pi` whose
# cmux ancestry was ERASED by reparenting), so it reopens on a filed issue with the measurement
# attached — never as a flag default, and never in a diff. `pi-reap-idle.sh`'s `gate3_allows`
# refuses every class for the same reason; that reaper's harvest is ZERO BY DECISION.
AUTHORISE_HOSTLESS_CHAINS = False


def ancestry_complete(chain: List[str]) -> bool:
    """False when the walk hit a hop missing from the snapshot (`ancestry()`'s own marker)."""
    return not any(a.startswith("<pid ") for a in chain)


def gate2_host_decision(chain: List[str]) -> Tuple[str, str]:
    """Classify a candidate's chain the way the recorded rule does: (kind, detail).

    kind is `human` | `unknown-incomplete` | `hostless`. The two `unknown` shapes are DISTINCT
    reasons so an operator can tell "the walk broke" from "the walk succeeded and found no
    owner"; both abstain, and neither is a licence to signal (#1207).
    """
    human = [h for h in HUMAN if any(h in a for a in chain)]
    if human:
        return "human", human[0]
    # ONE predicate for "the walk broke" (`ancestry_complete`, the named rule), so a future
    # change to what counts as an incomplete walk has one home instead of two.
    if not ancestry_complete(chain):
        return "unknown-incomplete", next((a for a in chain if a.startswith("<pid ")), "")
    return "hostless", " > ".join(chain[:6]) or "(empty chain)"

TOLERANCE_S = 0.10          # gate 1: below this the process is PARKED
HTTP_BUDGET_S = 8           # bound the launchctl call; an unbounded helper is an unbounded step


def ps_fields() -> dict[str, dict]:
    out = subprocess.run(["ps", "-Ao", "pid=,ppid=,pcpu=,time=,etime=,comm=,args="],
                         capture_output=True, text=True).stdout
    rows: dict[str, dict] = {}
    for ln in out.splitlines():
        p = ln.split(None, 6)
        if len(p) < 7:
            continue
        rows[p[0]] = {"pid": p[0], "ppid": p[1], "pcpu": p[2], "time": p[3],
                      "etime": p[4], "comm": p[5], "args": p[6]}
    return rows


def cpu_seconds(t: str) -> float:
    """`0:52.97` / `3124:47` / `01-19:48:27` -> seconds."""
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
    t = t.strip()
    days = 0.0
    if "-" in t:
        d, t = t.split("-", 1)
        days = float(d)
    parts = [float(x) for x in t.split(":")]
    return days * 86400 + sum(v * (60 ** i) for i, v in enumerate(reversed(parts)))


def etime_or_none(t: object) -> Optional[float]:
    """`etime_seconds` without the crash: a value the read did not establish is `None`.

    ⛔ A BAD VALUE IS NOT A CRASH, and it is not a ZERO either (the rule `_fence_from_env`
    states for the environment). The `pi` census has a per-row abstention for exactly this
    datum — `bind_session` -> `("start-unreadable", "ps etime unparseable")` — and that arm was
    STRUCTURALLY UNREACHABLE while the census's own sort key called `etime_seconds` unguarded:
    one unparseable `etime` anywhere in the table raised out of `pi_census` before a single row
    was scored, so `--json` emitted NO document, the four-state census was lost, and the run
    exited 1 — the code this file reserves for "an applied target survived".

    Neither direction may collapse here: `None` means "unreadable" and is scored as an
    abstention; `0.0` would be a claim that the process started at the epoch.
    """
    try:
        return etime_seconds(str(t))
    except (TypeError, ValueError):
        return None


def registered_launchd_pids() -> set[str]:
    """Gate 4. `launchctl list` prints PID/status/label. A pid present here is a MANAGED JOB."""
    pids: set[str] = set()
    for domain in ("system", f"gui/{os.getuid()}"):
        try:
            out = subprocess.run(["launchctl", "list"], capture_output=True, text=True,
                                 timeout=HTTP_BUDGET_S).stdout
        except Exception:
            # An unreadable domain must FAIL CLOSED (treat everything as registered) — a
            # resolver that fails open is how a reaper kills a daemon it could not see.
            return {"*UNREADABLE*"}
        for ln in out.splitlines()[1:]:
            f = ln.split()
            if f and f[0].isdigit():
                pids.add(f[0])
        break  # `launchctl list` covers the caller's domain; one read is enough
    return pids


DAEMONISH = re.compile(r"--loop|--daemon|--serve|--watch|--interval|--port|--listen|"
                       r"\bserve\b|\.pid\b", re.I)


def designed_daemon(pid: str, args: str) -> str | None:
    """Gate 5. Returns the evidence, or None. Intent leaves traces; an orphan does not."""
    if DAEMONISH.search(args):
        return "daemon-ish argv"
    # a pidfile naming this pid
    state = os.path.expanduser("~/.pi/agent/state")
    try:
        for f in os.listdir(state):
            if f.endswith(".pid"):
                try:
                    if open(os.path.join(state, f)).read().strip() == pid:
                        return f"pidfile {f}"
                except Exception:
                    pass
    except Exception:
        pass
    # a live holder of a socket this process owns, or a recently-written open file
    try:
        out = subprocess.run(["lsof", "-p", pid], capture_output=True, text=True,
                             timeout=5).stdout
    except Exception:
        return "lsof unreadable -> unclear"
    for ln in out.splitlines()[1:]:
        f = ln.split(None, 8)
        if len(f) < 9:
            continue
        kind, name = f[4], f[8]
        if "socket" in kind.lower() or "unix" in kind.lower():
            # FAIL CLOSED: a process holding a listening socket may have a live client, and the
            # NAME field for a listening unix socket is often EMPTY, so an lsof-by-name lookup
            # cannot be trusted to find the client. Holding a listener is therefore reported as
            # DESIGNED, not reaped — a stranded test server that could be safely reclaimed is a
            # job for its own owner (see the note above TESTISH).
            return f"holds a listening socket ({kind})"
        if kind in ("REG", "DIR") and name.startswith("/"):
            try:
                if time.time() - os.stat(name).st_mtime < 900:
                    return f"output written <15min ago: {name[:44]}"
            except Exception:
                pass
    return None


def ancestry(pid: str, rows: dict[str, dict], depth: int = 25) -> list[str]:
    """Walk parent chain TO THE TOP. Returns the path (comm strings)."""
    path, cur, seen = [], pid, set()
    while cur and cur != "0" and cur not in seen and depth > 0:
        seen.add(cur)
        r = rows.get(cur)
        if r is None:
            # Parent not in this snapshot (reparented to launchd, or exited between reads).
            # Record it as an unknown hop rather than silently stopping — an incomplete walk
            # must not read as a clean walk.
            path.append(f"<pid {cur} not visible>")
            break
        path.append(r["comm"])
        cur = r["ppid"]
        depth -= 1
    return path


# ═════════════════════════════════════════════════════════════════════════════════════════════
# THE `pi` SESSION POOL — four states, three gates, one verdict (header: "THE `pi` POOL")
# ═════════════════════════════════════════════════════════════════════════════════════════════
HERE = os.path.dirname(os.path.abspath(__file__))
SESSIONS_DIR = os.path.expanduser(os.environ.get("PI_SESSIONS_DIR", "~/.pi/agent/sessions"))

POOL_STATES = ("LIVE", "PARKED-REAPABLE", "KEEP-HUMAN", "UNVERIFIABLE")
# ⛔ THE FENCE IS THE CANON'S, NOT THIS FILE'S. `scripts/lib/pid-identity.sh:68` owns the
# tolerance (`FENCE_TOLERANCE_SECONDS`, default 3 s, env-overridable) and §3 of
# `docs/ops/fleet-liveness.md` forbids a second identity probe with a different bound. Read it
# from the same variable, with the canon's OWN default (a wider fence here is a silently weaker
# identity rule the canon cannot see). The default literal below is pinned to
# `pid-identity.sh:68`'s `${FENCE_TOLERANCE_SECONDS:-3}` by `orphan-reap.test.py`, so a change to
# the canon's tolerance goes RED here instead of silently diverging.
FENCE_DEFAULT_S = 3.0


def _fence_from_env(default: float = FENCE_DEFAULT_S) -> float:
    """The canon's fence, read defensively: a malformed value must never abort the tool.

    ⛔ A BAD VALUE IS NOT A CRASH. `float(os.environ[...])` evaluated at MODULE IMPORT turned one
    malformed `FENCE_TOLERANCE_SECONDS=3s` (a cell's keys.env, an operator's shell) into a
    traceback for EVERY invocation — `--help` and the pre-existing ORPHAN pool included — so a
    value the bash canon degrades to "not in fence" (i.e. abstain) aborted the reaper before it
    could abstain. Unset / unparseable / negative / non-finite falls back to the canon default and
    SAYS SO on stderr; it never silently widens the fence.
    """
    raw = os.environ.get("FENCE_TOLERANCE_SECONDS")
    if raw is None or not raw.strip():
        return default
    try:
        v = float(raw)
    except (TypeError, ValueError):
        v = float("nan")
    if v != v or v in (float("inf"), float("-inf")) or v < 0:
        print(f"orphan-reap: FENCE_TOLERANCE_SECONDS='{raw}' is not a non-negative number — "
              f"using the canon default {default:g} s", file=sys.stderr)
        return default
    return v


FENCE_S = _fence_from_env()
OUTLIER_FACTOR = 100       # gate 3: "two orders out" of the process's OWN expected interval
PI_TAIL_BYTES = 262_144    # same tail bound the liveness classifier reads
MIN_TAIL_ENTRIES = 5       # fewer stamped entries cannot establish an OWN distribution
STORE_PATH = os.path.expanduser(
    os.environ.get("PI_HOOK_STORE", "~/.cmuxterm/pi-hook-sessions.json"))
GATES = {"1": True, "2": True, "3": True}   # mutated ONLY by the test suite; never by the CLI


# ── the canon verdict, imported ──────────────────────────────────────────────────────────────
def fleet_liveness():
    """`tools/fleet/liveness.py` — the fleet's ONE verdict function (#1178). Imported, not copied."""
    cands = [os.environ.get("ORPHAN_REAP_FLEET_DIR", ""),
             os.path.join(HERE, "fleet"),                                  # farmed copy
             os.path.join(HERE, os.pardir, "tools", "fleet")]             # the repo
    for d in cands:
        if d and os.path.isfile(os.path.join(d, "liveness.py")):
            d = os.path.abspath(d)
            if d not in sys.path:
                sys.path.insert(0, d)
            try:
                import liveness as _liv  # noqa: PLC0415 - lazy: the orphan path needs no import
            except Exception:
                return None
            return _liv
    return None


# ── process table ────────────────────────────────────────────────────────────────────────
def ps_pi_fields() -> Optional[Dict[str, dict]]:
    """One `ps` read with `stat` (zombie) and `etime` — the pool's process evidence.

    ⛔ `None` IS A FAILED READ (review findings on #2334, cycles 2-3). `subprocess.run`'s status
    used to be dropped, so a `ps` that failed (rc≠0, no stdout) returned `{}` — byte-identical to
    "no process matched" — and every caller read that as a real, empty reading. The two most
    expensive shapes: the census said `0 to reap` and exited 0 on a read it never completed, and a
    second read that failed mid-window reported EVERY live lane as `vanished-mid-read`, a positive
    claim about live processes from a read that did not happen.

    So this reader is TWO-valued, and deliberately so: rows, or `None` for "the read did not
    complete". There is no `{}` answer to document — a successful `ps -Ao` always lists at least
    init, so "no parseable rows at all" IS a broken read, and it is folded into `None` here rather
    than handed to callers as an empty world. Callers nonetheless guard with `if not rows` (not
    `is None`), so a future edit that lets `{}` through cannot re-open the hole: the guard, not
    this docstring, is what holds.
    """
    proc = subprocess.run(["ps", "-Ao", "pid=,ppid=,stat=,time=,etime=,comm=,args="],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    rows: Dict[str, dict] = {}
    for ln in proc.stdout.splitlines():
        p = ln.split(None, 6)
        if len(p) < 7:
            continue
        rows[p[0]] = {"pid": p[0], "ppid": p[1], "stat": p[2], "time": p[3],
                      "etime": p[4], "comm": p[5], "args": p[6]}
    # a successful `ps -Ao` prints at least init; no parseable rows at all is a broken read.
    return rows or None


def is_pi(row: dict) -> bool:
    return os.path.basename(row.get("comm", "").strip()) == "pi"


# ── binding a pid to its session file ────────────────────────────────────────────────────────
_STAMP = re.compile(r"(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-(\d{3})Z_")


def _file_stamp_s(name: str) -> Optional[float]:
    """A session file's name-stamp as epoch seconds (the session's START, ms precision).

    ⛔ UTC, not local: the stamp ends in `Z`, so `time.mktime` (which reads a LOCAL struct_time)
    put it off by the host's UTC offset — 7200 s under Europe/Madrid — and every candidate fell
    outside the fence, silently making the whole pool UNVERIFIABLE on every non-UTC host.
    """
    m = _STAMP.search(name)
    if not m:
        return None
    y, mo, d, h, mi, s, ms = (int(x) for x in m.groups())
    try:
        import calendar
        return calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0)) + ms / 1000.0
    except Exception:
        return None


def session_index(sessions_dir: str = SESSIONS_DIR) -> List[Tuple[str, float]]:
    """Every session JSONL with its start stamp. A file without a stamp is not a candidate."""
    idx: List[Tuple[str, float]] = []
    for path in glob.glob(os.path.join(sessions_dir, "*", "*.jsonl")):
        ts = _file_stamp_s(os.path.basename(path))
        if ts is not None:
            idx.append((path, ts))
    return idx


def _session_cwd(path: str) -> Optional[str]:
    """The `cwd` recorded in a session's first line (a JSON, ~1 KiB read)."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for _ in range(3):
                line = fh.readline()
                if not line:
                    break
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                if isinstance(e, dict) and isinstance(e.get("cwd"), str):
                    return e["cwd"]
    except OSError:
        return None
    return None


def bind_session(pid: str, row: dict, ref_s: float, index: List[Tuple[str, float]],
                 taken: set[str]) -> Tuple[Optional[str], str, str]:
    """(path, binding, detail). UNIQUE name-stamp match inside the canon fence, or abstain.

    `ref_s` is the clock reading taken WITH the `ps` snapshot the `etime` came from — a reference
    taken after the sample window would slide every candidate out of the fence.

    ⛔ THE LADDER IS ONE RUNG ON PURPOSE. An argv `--session <sid>` form is NOT parsed here: which
    session a pid claims is `scripts/lib/pid-identity.sh`'s question (`probe-argv` /
    `argv-candidates`), and a local regex would be a second, narrower identity rule (it would miss
    `-r` / `--resume`) — the defect §3 of `docs/ops/fleet-liveness.md` forbids. A RESUMED session
    therefore keeps its original name-stamp, misses the fence, and ABSTAINS as
    `no-session-file`; that is the fail-closed direction and it is named in the census.
    """
    try:
        start = ref_s - etime_seconds(row["etime"])
    except Exception:
        return None, "start-unreadable", "ps etime unparseable"
    near = [(p, ts) for p, ts in index if abs(ts - start) <= FENCE_S]
    cwd = _cwd_of_pid(pid)
    if cwd is not None:
        # ⛔ AN UNREADABLE SESSION `cwd` IS NOT A MATCH. `in (None, cwd)` accepted a file whose
        # first lines carry no readable `cwd` for ANY pid, and `session_index` globs every
        # project subdirectory — so a foreign checkout's transcript could supply this row's
        # gate-3 age and own gap. The rest of this file reads a missing datum as an ABSTENTION
        # (`_stat` -> None => UNVERIFIABLE); this was the one place that read it as consent.
        near = [(p, ts) for p, ts in near if _session_cwd(p) == cwd]
    else:
        # ⛔ THE FILE SIDE IS FAIL-CLOSED EVEN WHEN THE PID SIDE CANNOT BE READ. `_cwd_of_pid`
        # returns None for another uid or a refused `lsof`, and the filter above was SKIPPED for
        # BOTH sides in that case — so a `cwd`-less transcript (which `session_index` will happily
        # offer, since it globs every project subdirectory) was still accepted for any pid and
        # could supply this row's gate-3 age and own gap. The pid side cannot be checked here, so
        # the file side must be: a session file with no readable `cwd` is never a candidate.
        near = [(p, ts) for p, ts in near if _session_cwd(p) is not None]
    near = [(p, ts) for p, ts in near if p not in taken]
    if not near:
        return None, "no-session-file", (f"no session file within ±{FENCE_S:g}s of start "
                                          f"(now-etime); a print-mode/task child writes none, "
                                          f"and a resumed session keeps its original stamp")
    if len(near) > 1:
        return None, "ambiguous-binding", ("%d sessions within ±%gs: %s" % (
            len(near), FENCE_S, ", ".join(os.path.basename(p)[:19] for p, _ in near[:4])))
    path, ts = near[0]
    detail = f"start ±{abs(ts - start):.1f}s of the file's name-stamp"
    if cwd is None:
        detail += "; pid cwd UNCHECKED (unreadable) — matched on fence + file cwd present only"
    return path, "fence", detail


_CWD_CACHE: Dict[str, Optional[str]] = {}


def _cwd_of_pid(pid: str) -> Optional[str]:
    """One lsof read per pid, cached. A refused read is None — and None makes `bind_session`
    SKIP the cwd filter, so the pid still binds by fence and still votes: not an abstention."""
    if pid in _CWD_CACHE:
        return _CWD_CACHE[pid]
    val: Optional[str] = None
    try:
        out = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fn", "-p", pid],
                             capture_output=True, text=True, timeout=5).stdout
        for line in out.splitlines():
            if line.startswith("n"):
                val = line[1:]
                break
    except Exception:
        val = None
    _CWD_CACHE[pid] = val
    return val


# ── the process's OWN expected distribution (gate 3's denominator) ───────────────────────────
def _iso_ms(stamp) -> Optional[int]:
    if not isinstance(stamp, str):
        return None
    try:
        from datetime import datetime
        return int(datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp() * 1000)
    except Exception:
        return None


def own_expected_gap_s(path: str) -> Tuple[Optional[float], int]:
    """(median inter-entry gap, entries read) from the transcript's own tail.

    This is "its own expected distribution": what THIS session normally does between entries.
    Fewer than MIN_TAIL_ENTRIES stamped entries cannot establish one — an ABSTENTION.
    """
    try:
        size = os.path.getsize(path)
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            if size > PI_TAIL_BYTES:
                fh.seek(size - PI_TAIL_BYTES)
                fh.readline()          # drop the partial line the seek landed in
            tail = fh.read()
    except OSError:
        return None, 0
    stamps: List[int] = []
    for line in tail.splitlines():
        try:
            e = json.loads(line)
        except Exception:
            continue
        ms = _iso_ms(e.get("timestamp")) if isinstance(e, dict) else None
        if ms is not None:
            stamps.append(ms)
    gaps = sorted((b - a) / 1000.0 for a, b in zip(stamps, stamps[1:]) if b > a)
    if len(gaps) < MIN_TAIL_ENTRIES:
        return None, len(gaps)
    mid = len(gaps) // 2
    median = gaps[mid] if len(gaps) % 2 else (gaps[mid - 1] + gaps[mid]) / 2
    return median, len(gaps)


@dataclass
class Transcript:
    path: str
    age_s: Optional[float]        # None: the file could not be stat'd (vanished between reads)
    grew: bool
    own_gap_s: Optional[float]
    n_entries: int                # GAPS counted (not stamps), so the reason never contradicts it


@dataclass
class PiEvidence:
    pid: str
    comm: str
    args: str
    etime_s: float
    cpu_before: float
    cpu_after: Optional[float]     # None: the pid VANISHED between the two reads
    zombie_after: bool
    recycled_mid_read: bool        # `etime` jumped BACKWARDS between the two census reads
    ancestry: List[str]
    self_ancestor: bool
    binding: str
    binding_detail: str
    transcript: Optional[Transcript]
    canon: Optional[Tuple[str, str]]      # (state, reason) from liveness.evaluate
    idle_floor_s: float = 86400.0         # canon IDLE_MS, supplied by the caller


def canon_verdict(liv, pid: str, tr: Transcript, now_ms: int, *, store_path: str,
                  sessions_dir: str):
    """The canon verdict over the CANON'S OWN evidence acquisition, not a lookalike.

    ⛔ THIS CALLS `liveness.gather` — the store is read, so the canon's record veto (#947) is
    live and an UNREADABLE store abstains (`unknown/store-unreadable`) instead of being assumed
    empty. The ONLY thing this file adds is the candidate this process read already proves: the
    live pid, which the canon's C2 direction ("a live writer with no store record is a
    candidate") admits and which `collect_candidates` cannot see for a bare-argv `pi`.
    A first draft asserted `store_ok=True` with `record=None`; that made the record veto
    structurally unreachable and turned a lane whose own record says it consumed input into an
    `idle` verdict — a fail-open widening of the kill authorisation, corrected here.
    """
    if liv is None or tr is None or tr.age_s is None:
        return None
    try:
        ev = liv.gather(
            session_sid(tr.path), store_path=store_path,
            # ⛔ THE CANON RE-READS THE FILE ITSELF — the caller only says WHERE it is. `gather`
            # resolves the JSONL from the sid PLUS the store record's `cwd`; with no record it
            # searches `sessions_dir` FLAT, which cannot see pi's real layout
            # `<sessions>/--<encoded-cwd>--/<stamp>_<sid>.jsonl`. The population this append
            # exists for is exactly "a live writer with NO store record", so the canon lost the
            # transcript and abstained `jsonl-age-unknown` while the same census row printed a
            # measured age — the row said its transcript age was both known and unknown, and
            # those lanes could never reach `idle`. Naming the bound file's own directory hands
            # the canon the one fact this process proved by binding it; the AGE stays the canon's.
            sessions_dir=os.path.dirname(tr.path) or sessions_dir,
            now_ms=now_ms,
        )
        # the process we are holding, as a HOLDER candidate (positive observation, never a guess)
        ev.candidates.append(liv.Candidate(int(pid), liv.HOLDER, "self", None))
        if tr.grew:
            # our own two reads measured growth; the canon's is an mtime heuristic. True only
            # ever ADDS fail-safe evidence (growth ⇒ running-quiet), so this is monotone.
            ev.jsonl_grew = True
        v = liv.evaluate(ev)
        return (v.state, v.reason)
    except Exception as exc:                      # an unpinned future field must abstain
        return ("unknown", f"evaluate-failed:{type(exc).__name__}")


def session_sid(path: str) -> str:
    """The session id a transcript filename carries: `<stamp>_<uuid>.jsonl`."""
    stem = os.path.basename(path)[:-len(".jsonl")] if path.endswith(".jsonl") else os.path.basename(path)
    return stem.rsplit("_", 1)[-1] if "_" in stem else stem


def pi_verdict(ev: PiEvidence, gates: Optional[Dict[str, bool]] = None
               ) -> Tuple[str, List[str], str]:
    """(state, gate readings, reason). Pure: no I/O, no clock. Gates 1-3 + the canon verdict."""
    g = dict(GATES)
    if gates:
        g.update(gates)
    readings: List[str] = []
    # `host_kind` is set by gate 2 below and CONSUMED at the bottom (the authorisation point).
    host_kind, host_detail = "authorised", ""

    # (0) A vanished pid is not a candidate — it is a read that did not complete.
    if ev.cpu_after is None:
        return "UNVERIFIABLE", ["pid vanished between the two reads"], "vanished-mid-read"
    if ev.zombie_after:
        return "UNVERIFIABLE", ["process is a zombie: only its parent can reap it"], "zombie"
    if ev.recycled_mid_read:
        # ⛔ THE RECYCLE CAN HAPPEN BETWEEN THIS CENSUS'S OWN TWO READS, and that window is the
        # one the binding was measured in. `_same_incarnation` fences the SIGNAL-time read against
        # `etime_after`, so it cannot see this: both of ITS readings are the new process, and it
        # would pass. The row would have bound the DEAD process's transcript (the fence keyed on
        # the before-read `etime`) and then SIGTERMed whoever now holds the pid. An `etime` that
        # moved backwards across the sample window is the signature, and it is a failed
        # measurement, not a row (#1696).
        return ("UNVERIFIABLE", ["pid was recycled between the two census reads: `etime` moved "
                                "backwards inside the sample window"], "recycled-mid-read")
    if ev.cpu_after < 0:
        # the after-sample row EXISTS but its `time=` did not parse: a failed read, not a
        # disappeared process (which is `cpu_after is None` above).
        return ("UNVERIFIABLE", ["gate 1 the after-sample CPU time was unparseable"],
                "cpu-unreadable")
    if ev.cpu_before < 0:
        # an unparseable FIRST read would otherwise make `after - before` a phantom positive
        # delta and promote the row to LIVE/cpu-advancing.
        return ("UNVERIFIABLE", ["gate 1 the before-sample CPU time was unparseable"],
                "cpu-unreadable")

    # (2) ANCESTRY FIRST — safety before any economy: a human's parked prompt is never a
    #     candidate, and the walk goes TO THE TOP (ppid 1 proves nothing on its own).
    if ev.self_ancestor:
        return "KEEP-HUMAN", ["ancestor of this reaper run"], "self-ancestor"
    if g["2"]:
        kind, detail = gate2_host_decision(ev.ancestry)
        if kind == "human":
            return ("KEEP-HUMAN",
                    [f"gate 2 ancestry -> {detail} at "
                     f"{' > '.join(ev.ancestry[:6])}"],
                    f"human-ancestor:{detail}")
        # ⚠️ The `unknown` kinds are NOT decided here. They are the HOST DECISION on the ACTION,
        # and deciding them before the measurement would collapse a LIVE row into an abstention —
        # destroying the census's one diagnostic job (telling progress from parked). They are
        # applied at the bottom, at the single point where a row would otherwise become
        # PARKED-REAPABLE. `human` stays first for the opposite reason: ownership is a fact about
        # the process, not about the measurement, and safety comes before economy.
        host_kind, host_detail = kind, detail

    # (1) CPU DELTA, tolerance named (TOLERANCE_S = 0.10 s over the printed window).
    delta = ev.cpu_after - ev.cpu_before
    if delta < 0:
        return ("UNVERIFIABLE", [f"gate 1 cpu delta={delta:.2f}s (negative: unreadable sample)"],
                "cpu-unreadable")
    if g["1"] and delta >= TOLERANCE_S:
        return ("LIVE", [f"gate 1 cpu delta={delta:.2f}s >= {TOLERANCE_S:.2f}s"], "cpu-advancing")
    readings.append(f"gate 1 cpu delta={delta:.2f}s < {TOLERANCE_S:.2f}s => PARKED")

    # (3) PROGRESS vs its OWN expected distribution. Growth beats CPU: a transcript that grew
    #     in the window is LIVE no matter what the CPU reading says.
    tr = ev.transcript
    if tr is None:
        return ("UNVERIFIABLE", readings + [f"gate 3 no transcript ({ev.binding})"],
                f"no-progress-channel:{ev.binding}")
    if tr.age_s is None:
        # the file was in the index and then could not be stat'd: an unreadable reading is an
        # ABSTENTION, never `age < bound` (which would have read LIVE).
        return ("UNVERIFIABLE", readings + ["gate 3 transcript unreadable (stat failed)"],
                "transcript-unreadable")
    if g["3"]:
        if tr.grew:
            return ("LIVE", readings + ["gate 3 transcript GREW in the window (progress beats CPU)"],
                    "transcript-growing")
        if tr.own_gap_s is None:
            return ("UNVERIFIABLE",
                    readings + [f"gate 3 own distribution unestablished "
                                f"({tr.n_entries} inter-entry gaps < {MIN_TAIL_ENTRIES})"],
                    "own-distribution-unestablished")
        bound = max(ev.idle_floor_s, OUTLIER_FACTOR * tr.own_gap_s)
        readings.append(f"gate 3 age={tr.age_s / 3600:.2f}h vs own bound={bound / 3600:.2f}h "
                        f"(own median gap={tr.own_gap_s:.1f}s x{OUTLIER_FACTOR})")
        if tr.age_s < bound:
            return "LIVE", readings, "progress-within-own-expected"
    else:
        readings.append("gate 3 DROPPED")

    # (4) THE CANON VERDICT — the kill authorisation, and it is never a second opinion.
    if ev.canon is None:
        return "UNVERIFIABLE", readings + ["canon verdict unavailable"], "canon-unavailable"
    state, reason = ev.canon
    if state != "idle":
        return ("UNVERIFIABLE", readings + [f"canon={state} ({reason}) — only `idle` authorises"],
                f"canon:{state}:{reason}")
    readings.append(f"canon=idle ({reason}) — retirement proof met")
    # (5) THE HOST DECISION — the last thing between a measured verdict and a SIGNAL, and the
    # only arm that can take an otherwise-reapable row away. #1207, verbatim: "Unknown/
    # unparseable chain ⇒ report only, never reap." Both unknown shapes abstain; a hostless chain
    # is `unknown` under option A and abstains unless that decision is REOPENED (the constant).
    # Reaching here means gates 1+3 and the canon all say parked-and-retired, so the readings
    # still carry the full measurement — the row is `UNVERIFIABLE` because it is NOT AUTHORISED,
    # not because it is unmeasured.
    if host_kind == "unknown-incomplete":
        return ("UNVERIFIABLE",
                readings + [f"gate 2 ancestry INCOMPLETE at {host_detail} — a chain that cannot "
                            f"be walked is never a clean one (#1207: report only, never reap)"],
                "ancestry-incomplete")
    if host_kind == "hostless" and not AUTHORISE_HOSTLESS_CHAINS:
        return ("UNVERIFIABLE",
                readings + [f"gate 2 host decision: no recognised host app ({host_detail}) ⇒ "
                            f"`unknown` under the recorded rule (#1207 option A) ⇒ report only, "
                            f"never reap"],
                "host-decision-hostless")
    # ⛔ AN ALLOW-LIST, NOT A DENY-LIST. `host_kind` starts as the literal `"authorised"` and is
    # only overwritten when gate 2 runs, so the fall-through to PARKED-REAPABLE authorised every
    # kind this file does not name — including the `cmux` report-only class the header says must
    # "stay report-only if it is ever added". A verdict exception that is not recognised must
    # ABSTAIN, never authorise: a new `gate2_host_decision` kind would otherwise become reapable
    # the day it lands, with nothing here to say so.
    if host_kind != "authorised":
        # `hostless` is the ONE kind the reopen seam may authorise; every other kind — a future
        # `cmux`-style report-only class included — abstains by default.
        if not (host_kind == "hostless" and AUTHORISE_HOSTLESS_CHAINS):
            return ("UNVERIFIABLE",
                    readings + [f"gate 2 host decision `{host_kind}` is not an AUTHORISING kind "
                                f"({host_detail}) — a class this reaper does not recognise is "
                                f"report-only, never a licence to signal"],
                    f"host-decision-unrecognised:{host_kind}")
    return "PARKED-REAPABLE", readings, "parked-and-retired"


def _census_unreadable(as_json: bool, error: str, message: str) -> None:
    """A census that could not be read: rc 2, and `--json` STILL speaks JSON.

    ⛔ THE JSON DOCUMENT OWNS STDOUT ON EVERY PATH — the FAILED reads included, not only the empty
    one. These two returns printed a prose sentence on stdout, so a consumer parsing
    `--pool pi --json` got a non-JSON document exactly when the read failed (the same shape that
    made `| jq` break on the empty pool, one path over) and had to special-case prose on a stream
    the contract says is the document. `error` names the failed read; `counts: null` keeps it
    distinguishable from a real census of zero.
    """
    if as_json:
        print(json.dumps({"pool": "pi", "error": error, "counts": None, "rows": [],
                          "gates": None}, indent=2))
    else:
        print(message)


def _self_chain(rows: Dict[str, dict]) -> set[str]:
    """Our own ancestry: this reaper must never classify a process it runs under."""
    chain, cur = set(), str(os.getpid())
    while cur and cur != "0" and cur not in chain and len(chain) < 40:
        chain.add(cur)
        r = rows.get(cur)
        if not r:
            break
        cur = r["ppid"]
    return chain


def pi_census(sample_s: float, *, apply: bool = False, as_json: bool = False,
              sessions_dir: Optional[str] = None, store_path: Optional[str] = None,
              gates: Optional[Dict[str, bool]] = None) -> int:
    """The dry-run census + optional SIGTERM of PARKED-REAPABLE only.

    Returns 0 on a completed census (dry run or applied), 1 when an applied target SURVIVED the
    signal, 2 when the census could not be read at all. A census that read NOTHING is exit 2,
    never "0 to reap" — absence of a reading is not evidence of absence (`lane-status.py`,
    `liveness.py` C3).
    """
    g = dict(GATES)
    if gates:
        g.update(gates)
    # resolved AT CALL TIME, never as a def-time default: a default pins the constant's value at
    # import, so an override (--sessions-dir / --store, or a test's fixture) would be ignored.
    sessions_dir = sessions_dir or SESSIONS_DIR
    store_path = store_path or STORE_PATH
    liv = fleet_liveness()
    if liv is None:
        # without the canonical predicate there is no verdict to act on, only a process table
        _census_unreadable(
            as_json, "liveness-unimportable",
            "orphan-reap: UNVERIFIABLE — the fleet verdict module (tools/fleet/liveness.py) "
            "could not be imported; no census was read")
        return 2
    before = ps_pi_fields()
    if not before:
        _census_unreadable(as_json, "ps-unreadable",
                           "orphan-reap: UNVERIFIABLE — `ps` returned nothing; no census was read")
        return 2
    # ⛔ THE FENCE REFERENCE IS THE MOMENT `etime` WAS READ, so it is taken HERE — before any
    # store glob or transcript stat. `now - etime` computed after those (let alone after the CPU
    # window) is off by their duration, and a whole-pool drift out of the fence reads as
    # "UNVERIFIABLE" — the "a read that did not complete" shape that must never be reported as
    # "nothing to reap".
    t0 = time.time()
    cpu_prev = {pid: cpu_seconds(r["time"]) for pid, r in before.items()}
    pi_pids = [pid for pid, r in before.items() if is_pi(r)]
    if not pi_pids:
        # an EMPTY pool is a real reading, and it is not the same as an unreadable one
        if as_json:
            # ⛔ THE JSON DOCUMENT OWNS STDOUT ON EVERY PATH, the empty one included. A prose
            # sentence here made `--pool pi --json | jq` fail to parse on the single most common
            # input (a box where no `pi` is running) while exiting 0, so the caller could not
            # tell "0 of everything" from "unparseable output" — and the human sentence is
            # exactly what the `--json` contract says stdout is not for.
            print(json.dumps({"pool": "pi", "sample_s": sample_s, "tolerance_s": TOLERANCE_S,
                              "fence_s": FENCE_S, "outlier_factor": OUTLIER_FACTOR,
                              "idle_floor_s": liv.IDLE_MS / 1000.0,
                              "counts": {s: 0 for s in POOL_STATES}, "rows": [], "gates": g},
                             indent=2))
        else:
            print("orphan-reap: the `pi` pool is EMPTY in this read "
                  "(0 LIVE / 0 PARKED-REAPABLE / 0 KEEP-HUMAN / 0 UNVERIFIABLE)")
        return 0
    # transcript size/mtime, read once BEFORE the window and once AFTER
    pre_index = session_index(sessions_dir)
    pre_stat = {p: _stat(p) for p, _ in pre_index}

    time.sleep(max(1.0, sample_s))

    after = ps_pi_fields()
    if not after:
        # ⛔ THE SECOND READ IS A CENSUS TOO, and this one had no guard at all: an empty/failed
        # read makes `cur is None` for every pid, so EVERY row is reported `vanished-mid-read` —
        # a positive claim about live processes that the read never established — exit 0, and
        # `--apply` then announces that the reapable set is EMPTY. A read that did not complete
        # is exit 2, never `0 to reap` (the same rule the first read already carries).
        _census_unreadable(as_json, "ps-unreadable",
                           "orphan-reap: UNVERIFIABLE — the second `ps` read (the CPU window) "
                           "returned nothing; every row would read as `vanished`")
        return 2
    index = pre_index
    taken: set[str] = set()
    now_s = time.time()
    now_ms = int(now_s * 1000)
    selfc = _self_chain(before)
    rows_out: List[dict] = []
    counts = {s: 0 for s in POOL_STATES}
    idle_floor_s = liv.IDLE_MS / 1000.0      # the canon's retirement proof, never a literal here

    def _longest_lived_first(p: str) -> float:
        # an UNREADABLE start sorts last rather than aborting the loop over the whole table
        v = etime_or_none(before[p]["etime"])
        return -1.0 if v is None else v

    for pid in sorted(pi_pids, key=_longest_lived_first, reverse=True):
        r = before[pid]
        cur = after.get(pid)
        path, binding, detail = bind_session(pid, r, t0, index, taken)
        tr = None
        st = None
        if path:
            taken.add(path)
            st = _stat(path)
            prev = pre_stat.get(path)
            grew = bool(prev and st and (st[1] != prev[1] or st[0] != prev[0]))
            gap, n = own_expected_gap_s(path)
            tr = Transcript(path=path, age_s=(now_s - st[0]) if st else None, grew=grew,
                            own_gap_s=gap, n_entries=n)
        ev_etime = etime_or_none(r["etime"])
        cur_etime = etime_or_none(cur["etime"]) if cur else None
        ev = PiEvidence(
            pid=pid, comm=r["comm"], args=r["args"],
            etime_s=(-1.0 if ev_etime is None else ev_etime),
            cpu_before=cpu_prev.get(pid, -1.0),
            # `cur is None` is a VANISHED pid; a row whose `time=` is unparseable is a failed
            # READ. Collapsing them reported "vanished-mid-read" for a fact the read never
            # established, so the two are kept apart (see pi_verdict's first two steps).
            cpu_after=(None if cur is None else
                       (cpu_seconds(cur["time"]) if cpu_seconds(cur["time"]) >= 0 else -1.0)),
            zombie_after=bool(cur and cur["stat"].startswith("Z")),
            # ⛔ THE MEASURED INCARNATION IS THE SAMPLE'S **BEFORE** READ (`r["etime"]`), and the
            # binding was fenced on it. A recycle inside the window makes `etime` move BACKWARDS;
            # `_same_incarnation` only ever saw the after-read, so it could not detect this.
            # an unparseable `etime` on either side is `None`, not a comparison: a recycle is
            # only ever claimed about two readings the read actually established.
            recycled_mid_read=bool(cur is not None and cur_etime is not None
                                   and ev_etime is not None
                                   and cur_etime + FENCE_S < ev_etime),
            ancestry=ancestry(pid, before),
            self_ancestor=pid in selfc,
            binding=binding, binding_detail=detail, transcript=tr,
            canon=(canon_verdict(liv, pid, tr, now_ms, store_path=store_path,
                                 sessions_dir=sessions_dir) if tr else None),
            idle_floor_s=idle_floor_s,
        )
        state, readings, reason = pi_verdict(ev, g)
        counts[state] += 1
        rows_out.append({"pid": pid, "state": state, "reason": reason, "readings": readings,
                         # carried so APPLY can re-read the evidence that AUTHORISED this row at
                         # signal time — identity alone is not the authorisation (review cycle 1)
                         "transcript": path,
                         "transcript_stat": (None if st is None else [st[0], st[1]]),
                         "n_entries": (None if tr is None else tr.n_entries),
                         "args": r["args"][:120], "binding": binding,
                         "binding_detail": detail,
                         "ancestry": ev.ancestry[:8],
                         "cpu_delta": (None if ev.cpu_after is None
                                       else round(ev.cpu_after - ev.cpu_before, 2)),
                         "age_h": (None if tr is None or tr.age_s is None
                                   else round(tr.age_s / 3600, 2)),
                         "etime": r["etime"],
                         "etime_after": (cur["etime"] if cur else None),
                         "own_gap_s": (None if not tr else tr.own_gap_s),
                         "canon": (None if ev.canon is None else "%s:%s" % ev.canon)})

    if as_json:
        print(json.dumps({"pool": "pi", "sample_s": sample_s, "tolerance_s": TOLERANCE_S,
                          "fence_s": FENCE_S, "outlier_factor": OUTLIER_FACTOR,
                          "idle_floor_s": idle_floor_s, "counts": counts, "rows": rows_out,
                          "gates": g}, indent=2))
        # the JSON document owns stdout; the apply log goes to stderr so `--json --apply` stays
        # parseable (a documented machine-readable mode may not be destroyed by its own action)
        return 0 if apply is False else _apply_parked(
            rows_out, apply, stream=sys.stderr,
            liv=liv, store_path=store_path, sessions_dir=sessions_dir)

    print(f"pool: pi · processes: {len(pi_pids)} · CPU sample window: {sample_s:.0f}s "
          f"· PARKED = delta < {TOLERANCE_S:.2f}s · fence ±{FENCE_S:g}s "
          f"· stopped = age >= max({int(idle_floor_s) // 3600}h, {OUTLIER_FACTOR}x own gap)")
    print(f"gates: 1={g['1']} 2={g['2']} 3={g['3']}\n")
    print(f"{'pid':>7}  {'state':<16} {'cpu_d':>7} {'age h':>7} {'own gap':>8}  "
          f"{'canon':<26} reason")
    for row in rows_out:
        d = "" if row["cpu_delta"] is None else "%.2f" % row["cpu_delta"]
        h = "" if row["age_h"] is None else "%.1f" % row["age_h"]
        gp = "" if row["own_gap_s"] is None else "%.1fs" % row["own_gap_s"]
        print(f"{row['pid']:>7}  {row['state']:<16} {d:>7} {h:>7} {gp:>8}  "
              f"{(row['canon'] or '-'):<26} {row['reason']}")
    print(f"\n==== {' · '.join(f'{counts[s]} {s}' for s in POOL_STATES)} ====")
    for row in rows_out:
        if row["state"] == "PARKED-REAPABLE":
            print(f"  would reap {row['pid']}: {row['binding_detail']}; "
                  f"{'; '.join(row['readings'][-2:])}")
        elif row["state"] == "UNVERIFIABLE":
            print(f"  abstain {row['pid']}: {row['reason']} — {row['binding_detail']}")
    print("declared blind spots: a `pi` whose session file cannot be bound (print-mode/task "
          "child, or a resumed session keeping its original name-stamp), a `pi` that SWITCHED "
          "session (`/new`, `/fork`, `/clone` — the abandoned file keeps the start stamp, so the "
          "fence binds the DEAD transcript and the row can read PARKED-REAPABLE for a lane still "
          "writing; #2475), a same-fence start "
          "in the same cwd, another uid's processes, a box where the cmux store is unreadable "
          "(every row that REACHES the canon abstains as `store-unreadable`; a row under a "
          "terminal/login-shell ancestor is `KEEP-HUMAN` from gate 2 before the canon VERDICT is "
          "consulted (the canon is still read; gate 2 supersedes its answer)), "
          "an interactive host missing from the HUMAN allowlist (a VS Code `Code Helper` cannot "
          "be matched at all — `ps -Ao comm=` is space-split — so such a session is caught only "
          "through a shell/terminal ancestor, or not at all), "
          "memory/fd pressure, and a live child of a parked parent it does not enumerate. "
          "A row the census cannot decide is UNVERIFIABLE above; a blind "
          "spot is NOT uniformly an abstention — a skipped cwd filter can still bind, speak and "
          "score LIVE, and a store-unreadable row under a terminal ancestor is KEEP-HUMAN.")
    if not apply:
        print("dry run — nothing was signalled (--apply is a separate, reviewed step).")
        if not AUTHORISE_HOSTLESS_CHAINS:
            print("⛔ the host decision is NOT authorised for this pool (#1207 option A): any row "
                  "reaching no recognised host app abstains, so the reapable set is EMPTY BY "
                  "DECISION. The census is the deliverable; arming it is a reopen, not a flag.")
        return 0
    return _apply_parked(rows_out, apply, liv=liv, store_path=store_path,
                         sessions_dir=sessions_dir)


def _stat(path: str):
    try:
        st = os.stat(path)
        return (st.st_mtime, st.st_size)
    except OSError:
        return None


def _apply_parked(rows_out: List[dict], apply: bool, stream=None, *, liv=None,
                  store_path: str = "", sessions_dir: str = "") -> int:
    """SIGTERM PARKED-REAPABLE only, re-verifying the AUTHORISATION at signal time.

    The census's readings are stale by construction; `lane-watchdog.py`'s #1696 lesson is that a
    pid recycled inside the measurement->signal window receives a signal meant for a corpse. So
    the pid must still be the SAME `pi` (comm) and still be the SAME incarnation (its `etime`
    within the canon fence of the one the census measured) before anything is sent.

    ⛔ IDENTITY IS NOT THE AUTHORISATION (review cycle 1). The census called this row
    PARKED-REAPABLE because its transcript was STOPPED and the store record did not veto it
    (#947). Those two readings authorise the signal and are just as stale as the identity, so
    `_authorisation_holds` re-takes BOTH immediately before each `os.kill` — the same discipline
    `lane-watchdog.py` applies by forking its CLI at signal time. Without it, a lane that
    received a prompt during the census loop's forks keeps its identity and would still be
    signalled: the in-flight turn destroyed, which is the exact outcome this pool exists to
    avoid.
    """
    out = stream or sys.stdout

    def log(msg: str) -> None:
        print(msg, file=out)

    if not apply:
        return 0
    live = ps_pi_fields()
    target = [r for r in rows_out if r["state"] == "PARKED-REAPABLE"]
    if not target:
        if not AUTHORISE_HOSTLESS_CHAINS:
            log("apply: no PARKED-REAPABLE rows — the reapable set is EMPTY BY DECISION "
                "(#1207 option A keeps every unrecognised chain report-only); nothing signalled")
        else:
            log("apply: no PARKED-REAPABLE rows — nothing signalled")
        return 0
    if not live:
        # ⛔ AN UNREADABLE `ps` IS NOT A CLEAN TABLE. The census already refuses this shape
        # ("`ps` returned nothing; no census was read" -> exit 2); the apply path must too.
        # Without this guard every target below falls to `cur is None` and the run reports
        # "nothing done" with exit 0 — a success minted from an absent reading.
        log("apply: UNVERIFIABLE — the pre-signal `ps` read returned nothing, so no target's "
            "identity can be re-verified at signal time; NOTHING signalled (a pid/comm check "
            "against an absent reading is not a check)")
        return 2
    log(f"apply: {len(target)} PARKED-REAPABLE")
    sent = set()          # pids actually signalled — the ONLY rows a `survived` claim may cover
    for row in target:
        pid = row["pid"]
        cur = live.get(pid)
        if cur is None:
            log(f"  {pid} vanished before signal — nothing done")
            continue
        if not is_pi(cur):
            log(f"  {pid} REFUSED: the pid is no longer a `pi` (recycled) — nothing done")
            continue
        if not _same_incarnation(row, cur):
            log(f"  {pid} REFUSED: incarnation changed (etime moved) — nothing done")
            continue
        # gate 2 IS RE-CHECKED HERE (the #1696 lesson: identity at signal time, not earlier) —
        # and it is the SAME decision the census applied. A re-check that asks a weaker question
        # than the census asked is not a re-check.
        chain = ancestry(pid, live)
        kind, detail = gate2_host_decision(chain)
        if kind == "human":
            log(f"  {pid} REFUSED: human ancestor ({detail}) appeared between the census and "
                f"the signal")
            continue
        if kind == "unknown-incomplete":
            log(f"  {pid} REFUSED: ancestry INCOMPLETE at {detail} at signal time — a chain that "
                f"cannot be walked is never a licence to signal (#1207)")
            continue
        if not AUTHORISE_HOSTLESS_CHAINS:
            # the SAME allow-list the census applies (mirror of `pi_verdict`'s final block): with
            # the seam shut, `hostless` is not an authorising kind, and a re-check that asks a
            # WEAKER question than the census asked is not a re-check (#1696).
            log(f"  {pid} REFUSED: host decision — no recognised host app ({detail}) is `unknown` "
                f"under the recorded rule (#1207 option A): report-only until that decision is "
                f"reopened")
            continue
        if kind not in ("authorised", "hostless"):
            # ⛔ THE CENSUS ABSTAINS ON A KIND IT DOES NOT RECOGNISE (allow-list); the signal
            # re-check must abstain on exactly the same kinds, or a class that is report-only at
            # census time becomes a licence to signal at signal time — the one place it matters.
            log(f"  {pid} REFUSED: host decision `{kind}` is not an AUTHORISING kind ({detail}) "
                f"at signal time — a class this reaper does not recognise is report-only, never "
                f"a licence to signal")
            continue
        ok, why = _authorisation_holds(row, liv, store_path, sessions_dir)
        if not ok:
            log(f"  {pid} REFUSED: {why} — nothing done")
            continue
        try:
            os.kill(int(pid), 15)
            sent.add(pid)
            log(f"  SIGTERM -> {pid}")
        except ProcessLookupError:
            log(f"  {pid} already gone")
        except PermissionError:
            log(f"  {pid} EPERM — not ours to kill; REPORTING")
    time.sleep(3)
    still = ps_pi_fields()
    if not still:
        # ⛔ THE SAME RULE ON THE OTHER SIDE OF THE SIGNAL. A failed/empty read would make the
        # loop below print `verified gone` for EVERY target and return 0 — a reap that did not
        # happen, reported as verified. Absence of a reading is not evidence of absence (the
        # census's own rule), and `verified gone` is a claim about live processes.
        log("apply: UNVERIFIABLE — the post-signal `ps` read returned nothing; the signalled "
            "set was NOT verified (an absent reading is not evidence of death). Nothing below "
            "is reported as `verified gone`")
        return 2
    stuck = 0
    for row in target:
        pid = row["pid"]
        if pid not in sent:
            # ⛔ NOTHING WAS SIGNALLED FOR THIS ROW, so it is not a survivor. Counting its
            # presence as `STILL ALIVE` asserted that a SIGTERM was sent and survived when the
            # row was refused or had already vanished — a false report, and one that turned
            # the documented "exit non-zero when a target survives" contract into an exit 1 for
            # a target that never existed (review cycle 1).
            log(f"  not signalled: {pid}")
            continue
        alive = still.get(pid)
        # A ZOMBIE HAS ALREADY EXITED: it keeps its comm and its `etimes`, and `os.kill` on a `Z`
        # returns 0 — so presence + `is_pi` alone would report a process that is dead as a survivor.
        # And a pid recycled into ANOTHER `pi` inside the 3 s window is not the row we signalled, so
        # the incarnation is re-checked here too (`pi_verdict` already treats a zombie as a
        # non-answer; this loop uses the same vocabulary rather than a weaker one).
        if (alive is not None and is_pi(alive)
                and not alive["stat"].startswith("Z")
                and _same_incarnation(row, alive)):
            stuck += 1
            log(f"  STILL ALIVE (no SIGKILL for this pool — reporting): {pid}")
        else:
            log(f"  verified gone: {pid}")
    if stuck:
        # a caller must be able to tell "reaped the set" from "asked and nothing died"
        log(f"apply: {stuck} of {len(sent)} signalled target(s) survived SIGTERM — "
            f"reporting, not retrying")
        return 1
    return 0


def _authorisation_holds(row: dict, liv, store_path: str, sessions_dir: str):
    """Re-read AT SIGNAL TIME the readings that made this row PARKED-REAPABLE.

    WHAT IS RE-TAKEN HERE: the transcript's stat (absent / present / CHANGED), the canon verdict
    including the store record — plus, in the CALLER, bare `is_pi`, the incarnation and the host
    decision. WHAT IS NOT RE-TAKEN, and it is named here rather than left to be inferred: gate 1's
    CPU delta and gate 3's own-median bound. The transcript's AGE is re-derived from the fresh
    stat (monotone, so a stale age can only overstate the margin), and `own_gap_s` is carried from
    the census, but the CPU window is not re-sampled — so a lane that starts WORKING inside the
    census→signal window without appending to its transcript keeps its identity and would still
    receive the signal. That arm is not reachable today (the host decision refuses every row while
    `AUTHORISE_HOSTLESS_CHAINS` is False, and `_apply_parked` signals nothing); re-sampling the
    CPU delta is part of the work of reopening that seam, not an optional tidy-up.

    Returns (True, "") or (False, <reason>). Every refusal is fail-closed: an unreadable
    transcript, a changed transcript, a missing reader or a canon verdict that is no longer
    `idle` all decline to signal. Refusing is the safe direction — it leaves a parked process
    parked, which the next census re-measures; signalling on a stale reading destroys a lane.
    """
    path = row.get("transcript")
    if not path:
        return False, ("no transcript was bound at census time, so the stopped-reading that "
                       "authorised this row cannot be re-taken")
    now_st = _stat(path)
    if now_st is None:
        return False, ("the transcript re-read FAILED at signal time — an absent reading is not "
                       "evidence that the lane is still parked")
    was = row.get("transcript_stat")
    if was and (now_st[0] != was[0] or now_st[1] != was[1]):
        return False, ("the transcript CHANGED since the census — the lane consumed input in "
                       "the measurement->signal window")
    if liv is None:
        return False, "no liveness reader at signal time, so the store record cannot be re-read"
    now_ms = int(time.time() * 1000)
    # `grew=False` is NOT an assumption that the lane is quiet: growth is detected by the stat
    # comparison ABOVE, which returns before this line. Passing `grew=True` "to be conservative"
    # made every row derive `running-quiet:jsonl-grew` and refuse — a guard that can never
    # authorise is not a guard, it is an off switch (review cycle 1 caught exactly that).
    tr = Transcript(path=path, age_s=time.time() - now_st[0], grew=False,
                    own_gap_s=row.get("own_gap_s"), n_entries=row.get("n_entries") or 0)
    canon = canon_verdict(liv, row["pid"], tr, now_ms, store_path=store_path,
                          sessions_dir=sessions_dir)
    if canon is None:
        return False, "the canon verdict could not be re-derived at signal time"
    state, reason = canon
    if state != "idle":
        return False, f"the canon verdict is no longer `idle` ({state}:{reason})"
    return True, ""


def _same_incarnation(row: dict, cur: dict) -> bool:
    """Same process, not a recycled pid: its elapsed time must not have jumped backwards.

    BOTH the after-read (`etime_after`, what `_apply_parked` compares against) AND the MEASURED
    incarnation (`etime`, the before-read the binding and the verdict were fenced on) are
    floors. The after-read alone was not enough: a pid recycled inside the census's own sample
    window leaves after-read and signal-time read both describing the NEW process, so comparing
    them passes — while the row was bound on the OLD one. `pi_verdict` rejects that row as
    `recycled-mid-read`; this floor is the second, independent guard on the signal path.
    """
    try:
        was = etime_seconds(row.get("etime_after") or row.get("etime") or "")
        measured = etime_seconds(row.get("etime") or "")
        now = etime_seconds(cur["etime"])
    except Exception:
        return False
    if was < 0 or now < 0:
        return False
    # A RECYCLED pid is a NEWER process, so its etime is LOWER; the same process read later has a
    # slightly HIGHER one (age grew). Requiring `now + FENCE_S >= was` therefore rejects a jump
    # BACKWARDS — the recycle — while tolerating the fence's rounding. (The earlier comment said
    # the opposite, which would invert the check if anyone "fixed" the code to match it.)
    if not now + FENCE_S >= was:
        return False
    # the incarnation the row was MEASURED on: an unreadable floor cannot license a signal
    if measured < 0:
        return False
    return now + FENCE_S >= measured


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="actually SIGTERM (default: dry run)")
    ap.add_argument("--sample", type=float, default=15.0, help="CPU sample window, seconds")
    ap.add_argument("--pool", choices=("orphan", "pi", "all"), default="orphan",
                    help="which population to census (default: the ppid=1 orphan class only; "
                         "`pi` is the session pool with the four states)")
    ap.add_argument("--json", action="store_true", help="machine-readable census (pi pool)")
    ap.add_argument("--sessions-dir", default=SESSIONS_DIR, help="override the session store")
    ap.add_argument("--store", default=STORE_PATH,
                    help="override the cmux hook store the canon verdict reads")
    ap.add_argument("--include-any-owner", action="store_true",
                    help="do not require the path to be under YOUR Documents/GitHub")
    a = ap.parse_args()

    # `--json` documents a MACHINE-READABLE census and only the pi pool HAS one. Ignoring the flag
    # on the default pool returns prose where a caller expects JSON, and running it after the pi
    # document puts TWO documents on stdout (a caller's parse then fails on the second). Neither
    # is a documented mode, so both are refused with the way to get what was probably wanted.
    if a.json and a.pool != "pi":
        print("orphan-reap: --json is the `pi` pool's census format only. Use `--pool pi --json` "
              "for the machine-readable pool census; the orphan class has no JSON form — run it "
              "separately (`--pool orphan`) rather than concatenating two documents on stdout",
              file=sys.stderr)
        return 2

    rc_pi = None
    if a.pool in ("pi", "all"):
        rc_pi = pi_census(a.sample, apply=a.apply, as_json=a.json, sessions_dir=a.sessions_dir,
                          store_path=a.store)
        if a.pool == "pi":
            return rc_pi
        print()

    before = ps_fields()
    reg = registered_launchd_pids()

    cands = {}
    for pid, r in before.items():
        if r["ppid"] != "1":
            continue
        if not (OURS.search(r["args"]) or (a.include_any_owner and TESTISH.search(r["args"]))):
            continue
        if not TESTISH.search(r["args"]):
            continue
        cands[pid] = r

    print(f"candidates (ppid=1, ours, test/tooling-shaped): {len(cands)}")
    print(f"CPU sample window: {a.sample:.0f}s   (PARKED = delta < {TOLERANCE_S}s)\n")
    time.sleep(a.sample)
    after = ps_fields()

    reap, report = [], []
    for pid, r in sorted(cands.items(), key=lambda kv: etime_seconds(kv[1]["etime"]),
                         reverse=True):
        now = after.get(pid)
        if now is None:
            print(f"  {pid}  EXITED during sample — nothing to do")
            continue
        d = cpu_seconds(now["time"]) - cpu_seconds(r["time"])
        if d < 0:
            d = -1.0
        parked = 0.0 <= d < TOLERANCE_S
        elapsed = etime_seconds(r["etime"])
        path = ancestry(pid, before)
        human = [h for h in HUMAN if any(h in p for p in path)]
        is_reg = pid in reg
        designed = designed_daemon(pid, r["args"])
        # gate 3: our test/tooling class should finish in minutes; >=2h is two orders out.
        overlong = elapsed >= 2 * 3600

        verdicts = {
            "1_cpu": "PARKED" if parked else ("NEEDS-READ" if d < 0 else f"ALIVE +{d:.2f}s"),
            "2_ancestry": "human:" + human[0] if human else "no-human-ancestor",
            "3_expected": f"{elapsed/3600:.1f}h " + ("OVERLONG" if overlong else "plausible"),
            "4_launchd": "REGISTERED (never reap)" if is_reg else "unmanaged",
            "5_designed": designed or "no daemon trace",
        }
        print(f"  {pid}  {r['comm']}")
        print(f"        {r['args'][:130]}")
        for k, v in verdicts.items():
            print(f"        gate {k:12s} {v}")

        if is_reg or human or designed or not parked or not overlong:
            report.append((pid, verdicts))
            print("        => REPORT ONLY (a gate did not pass)\n")
        else:
            reap.append((pid, r))
            print("        => PASSES ALL FIVE GATES\n")

    print(f"==== {len(reap)} reapable · {len(report)} report-only ====")
    if not a.apply:
        print("dry run — re-run with --apply to SIGTERM the reapable set.")
        return 0

    for pid, r in reap:
        try:
            os.kill(int(pid), 15)
            print(f"  SIGTERM -> {pid} ({r['comm']})")
        except ProcessLookupError:
            # ⛔ `print`, NOT `log`: `log` is the closure defined INSIDE `_apply_parked`. This is
            # the ORPHAN pool's apply path (a different function), where an undefined `log` would
            # raise NameError on the first vanished/EPERM target — aborting the loop AFTER part of
            # the set was already signalled, skipping the post-apply `ps` verification and the
            # exit-code contract (a partial reap reported as a traceback).
            print(f"  {pid} already gone")
        except PermissionError:
            print(f"  {pid} EPERM — not ours to kill; REPORTING")
    time.sleep(3)
    still = ps_fields()
    for pid, r in reap:
        if pid in still:
            try:
                os.kill(int(pid), 9)
                print(f"  SIGKILL -> {pid} (did not exit on TERM)")
            except Exception as e:
                print(f"  {pid} still alive, kill failed: {e}")
        else:
            print(f"  verified gone: {pid}")
    # `--pool all`: the `pi` census's status IS this run's status (it is the only census that
    # returns one — 0/1/2 above). A silent 0 here would report success for a pi census that read
    # nothing; the orphan class contributes no status of its own, so this is not a max over two.
    return max(0 if rc_pi is None else rc_pi, 0)


if __name__ == "__main__":
    sys.exit(main())
