#!/usr/bin/env python3
"""tools/fleet/outcome_canary.py — assert what the FLEET PRODUCES, and raise a signal when it doesn't.

WHY THIS EXISTS (every clause below is a measured failure, not a worry)
-----------------------------------------------------------------------
Every fleet failure of the week ending 2026-10-18 was invisible to unit tests, because a unit test
asserts that a FUNCTION RETURNS what it was written to return. The fleet's failures were that the
SYSTEM DID NO WORK while each part reported itself healthy:

  * the controller was RUNNING and dispatching nothing (a live pid with a silent log);
  * the boxes were UP with no controller at all (launchd had no pid);
  * `cmux-tui` was OOM-killed while the systemd unit still read `active`;
  * landers expired silently, so green PRs waited for a human;
  * `pr-doctor` exited 2 for hours;
  * a refresh that could not read the pool idled the box all evening (`queue=UNREADABLE` beside
    `backlog=0`, reading as "nothing to do" — agent-infra#1931).

In each case the tests were green and the system produced nothing. So this file asserts OUTCOMES —
"a controller cycled", "work was dispatched", "a PR merged" — and, when one is absent, RAISES A
SIGNAL instead of returning a number nobody reads.

THE CHECKS (each an outcome; each has an ABSENT and a STALE variant)
-------------------------------------------------------------------
  1. controller_cycling   a controller process exists AND its log advanced within the window.
                          A running pid with a frozen log is the exact shape of "alive but useless",
                          so the pid alone is never enough.
  2. queue_readable       the last refresh produced a READABLE verdict — not `UNREADABLE`, not
                          `UNKNOWN` (never read at all), not `PARTIAL` — and not "backlog empty"
                          while the pool it just read holds a large number of issues.
  3. work_dispatched      a `[dispatch] … -> <issue>` line exists within the window AND that
                          batch's lane spawn (`#N: lane-N (implement+PR)`, for one of ITS issues, not
                          refuted by its own failure line) follows it — the batch line is an INTENT,
                          written before the spawner runs, so an intent with no outcome is
                          INCONCLUSIVE, never a PASS. THIS is the
                          outcome that matters most: every check above can pass while it fails
                          (measured 2026-10-18: 47 candidates, 47 `could not build claim commit`
                          refusals, zero dispatches, controller cycling and queue READ(223)).
  4. pr_created           at least one PR was opened in the window.
  5. pr_merged            at least one PR merged in the window. A fleet that creates but never
                          merges is broken even though every component is "up".
  6. pane_daemon          a live `cmux-tui` exists AND its OOM protection is demonstrated.
  7. headroom             free disk and available memory above the configured floors, with the
                          NUMBERS reported (a pass must be as legible as a failure).
  8. landers              every green, mergeable PR has an armed lander (or is railed); none
                          silently expired.

TWO MODES
---------
  --static [--fixtures-dir DIR]   every check evaluated against INJECTABLE fixtures, no network,
                                  no process table, no clock. A change that breaks a predicate fails
                                  a normal test run. Each fixture declares `_expect`, so the fixture
                                  set is an executed claim about the predicates, not documentation.
  --live [--box NAME]             the same predicates over THIS machine (or a named cmux cloud
                                  machine via `cmux cloud exec`). This is the mode that catches
                                  "it is up but doing nothing".

THE DESIGN RULE THAT MAKES THE FIXTURES POSSIBLE
------------------------------------------------
**Predicates never read the clock and never read a file.** They consume AGES in seconds
(`log.age_s`, `events[].age_s`) and already-computed booleans, never `now` and never a path. The
collector turns a machine into that shape; a fixture is the same shape written by hand. That is
what makes `--static` an evaluation of THE REAL PREDICATE rather than a second, parallel
implementation of it — the defect `docs/ops/fleet-liveness.md` names ("one verdict function, never
a second").

INCONCLUSIVE IS NOT GREEN
-------------------------
`PASS | FAIL | INCONCLUSIVE`. A check whose inputs could not be read (no network, no `/proc`, an
unreadable log, a gh refusal) is INCONCLUSIVE, it is rendered differently from PASS, and it makes
the exit code non-zero. An unevaluable check must NEVER read as green: that is how a blind fleet
looks healthy.

THE SIGNAL
----------
On a non-PASS check the canary:
  a. respawns the controller IF AND ONLY IF it is genuinely absent (`launchctl kickstart -k`, then
     `bootstrap`; NEVER `unload -w`/`load -w`, which write a PERSISTENT Disabled override and
     leave the controller removed AND disabled — the 2026-10-17 measured outage, #1975), then
     re-checks and reports whether the respawn took;
  b. otherwise sends the controller a message through the SANCTIONED path (`scripts/safe-send.sh`
     → `lane-guard.py` + `cmux_dispatch.py`), never a bare `cmux send`. The message carries the
     FAILING CHECK, the EVIDENCE (log line, numbers, timestamps), a one-line ORIENTATION pointer
     into `scripts/orchestrator-harness/README.md` naming the SECTION, and the NEXT COMMAND. A
     message that only says "something is wrong" is not acceptable, and a refused send is reported
     as NOT DELIVERED (with the guard's reason) rather than counted as sent;
  c. rate-limits itself to ONE MESSAGE PER STATE CHANGE, keyed on `(box, check, variant)`. A
     message per poll becomes noise, and noise is the failure that makes alerting worthless. A key
     is recorded as notified ONLY after a confirmed delivery, so a refused send is retried on the
     next poll and a delivered one is not repeated;
  d. exits non-zero — 1 if any check FAILED, 2 if nothing failed but something was INCONCLUSIVE —
     so a scheduler or CI sees it.

ORIENTATION POINTERS live in `ORIENTATION` below, one README section per check. They are pointers
into the harness's own documentation, not a second copy of it.

USAGE
-----
    python3 tools/fleet/outcome_canary.py --static
    python3 tools/fleet/outcome_canary.py --static --fixture tests/fixtures/outcome-canary/dispatch-refused.json
    python3 tools/fleet/outcome_canary.py --live                     # this machine
    python3 tools/fleet/outcome_canary.py --live --box cell-2        # a cmux cloud machine
    python3 tools/fleet/outcome_canary.py --live --dry-run           # report, never send/respawn
    python3 tools/fleet/outcome_canary.py --live --json

Exit: 0 all PASS · 1 ≥1 FAIL · 2 no FAIL but ≥1 INCONCLUSIVE · 3 usage error.
"""

from __future__ import annotations

import argparse
import calendar
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import traceback
import time

# ── status vocabulary ────────────────────────────────────────────────────────────────────────────
PASS = "PASS"
FAIL = "FAIL"
INCONCLUSIVE = "INCONCLUSIVE"

# ── the checks, in report order ──────────────────────────────────────────────────────────────────
# The probes `--skip` may name — one, deliberately small list. A typo used to be a silent no-op.
SKIPPABLE = ("github",)

CHECK_ORDER = [
    "controller_cycling",
    "queue_readable",
    "work_dispatched",
    "pr_created",
    "pr_merged",
    "pane_daemon",
    "headroom",
    "landers",
]

# One line per check: the README section a reader is pointed AT, so the message is actionable
# without re-deriving the diagnosis. These are the harness's own sections, verified against
# scripts/orchestrator-harness/README.md — they are pointers, never a paraphrase of the doc.
ORIENTATION = {
    "controller_cycling": (
        'scripts/orchestrator-harness/README.md §4 "Install" step 4 — "Start it when you mean to, '
        'and have the start PROVEN, not assumed" (plus §6.5.6, why a routine install must not be '
        'able to remove the controller)'
    ),
    "queue_readable": (
        'scripts/orchestrator-harness/README.md §7.2e — "A refresh that cannot READ the pool '
        'reported an empty queue" (EMPTY / READ(n) / PARTIAL / UNREADABLE, one vocabulary)'
    ),
    "work_dispatched": (
        'scripts/orchestrator-harness/README.md §7.2d — "ISSUE dispatch was the uncovered window" '
        '(claims + the dispatch path), and §6 "Detecting a hung worker"'
    ),
    "pr_created": (
        'scripts/orchestrator-harness/README.md §7.2b — cross-box duplicate work (a claim lost or '
        'never taken shows up here first, as a fleet that dispatches and opens nothing)'
    ),
    "pr_merged": (
        'scripts/orchestrator-harness/README.md §5 "Merge policy and safety invariants"'
    ),
    "pane_daemon": (
        'scripts/orchestrator-harness/README.md §6.5 — "Self-healing: wedges" (what must survive a '
        'machine-level failure) and docs/ops/fleet-liveness.md'
    ),
    "headroom": (
        'scripts/orchestrator-harness/README.md §4 "Tuning" — MIN_MEM_FREE_MB / MIN_SWAP_FREE and '
        'why the swap gate, not MAX_LANES, throttles an 8 GB box'
    ),
    "landers": (
        'scripts/orchestrator-harness/README.md §5 — the rail vs `--auto` mode (an armed lander and '
        'a railed PR are both legitimate; a green PR with NEITHER is the silent expiry)'
    ),
}

NEXT_COMMAND = {
    "controller_cycling": "bash scripts/orchestrator-harness/install.sh --start   # renders + bootstraps + PROVES pid and heartbeat",
    "queue_readable": "bash $O/refresh-candidates.sh --check   # then: cat $O/state/queue-state (its usage is [LIMIT] or --check, NOT a repo)",
    "work_dispatched": "bash -c '. $O/claims.sh; claim_issue_preflight <issue>'   # claims.sh is a SOURCED library — running it as a script only defines functions; the refusal reason is also on the [dispatch] line in tail -60 $O/logs/orch-loop.log",
    "pr_created": "tail -40 $O/logs/orch-loop.log   # then: bash $O/report.sh   (lanes vs dispatched vs created)",
    "pr_merged": "bash scripts/orchestrator-harness/report.sh   # then: gh pr list --state open --json number,mergeStateStatus,autoMergeRequest",
    "pane_daemon": "pgrep -fl cmux-tui   # then relaunch the pane daemon; a dead cmux-tui takes every lane's surface with it",
    "headroom": "df -h / && vm_stat   # free disk and available memory, against the floors in this report",
    "landers": "gh pr list --state open --json number,mergeStateStatus,autoMergeRequest | jq '.[] | select(.autoMergeRequest==null)'",
}


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Configuration
# ════════════════════════════════════════════════════════════════════════════════════════════════


class Cfg(object):
    """Everything a predicate may consult. Immutable in practice; fixtures may override any field."""

    DEFAULTS = {
        # How old an EMPTY pool READ may be before it stops being evidence. 90 minutes: the harness's
        # own token formatter switches from minutes to hours at 5400s, so this is the repo's existing
        # boundary for "this read is old enough to matter" rather than a number invented here.
        "queue_stale_s": 5400.0,
        # How long a "recent" outcome may be before it is stale. 720s = 3 cycles of a 240s cell.
        "window_s": 720.0,
        # PRs are coarser than cycles: a healthy fleet at night can legitimately go an hour without
        # opening one. 3h catches the 12h-silent failure without firing on a quiet window.
        "pr_window_s": 10800.0,
        # Floors. MIN_MEM_FREE_MB mirrors the harness's own MIN_MEM_FREE_MB default; the disk floor
        # is stated in GB because that is the unit `df` reports and a human reasons in.
        "mem_floor_mb": 512.0,
        "disk_floor_gb": 20.0,
        # A pool this large next to an EMPTY dispatch backlog is a failure of the refresh, not
        # idleness (agent-infra#1931).
        "pool_threshold": 25,
        # How many open PRs the REST fallback probes with per-PR detail + check-runs calls. A PR
        # beyond this bound is `probed: False` and reaches `landers` as PARTIAL_POPULATION, so the
        # bound is a VERDICT input and a knob — not an internal constant.
        "rest_probe_max": 25,
        # Which README/doc a failure points at is per-check (ORIENTATION), not configurable.
        "respawn_timeout_s": 40.0,
        "label": "com.eldato.orchestrator-loop",
        "repo": "",
        # Set by cfg_from_args / fixtures; None is a legitimate value ("not configured").
        "o_dir": None,
        "log_path": None,
        "box": "local",
        "controller_ws": None,
        # WHICH pane is named as the controller — part of explaining a verdict, like `controller_ws`:
        # two runs that message two different panes emitted byte-identical config blocks without it.
        "controller_name": None,
        "state_path": None,
    }

    # ⛔ THE KNOBS A NUMERIC VALUE FLOWS INTO, AND THE BOUNDS THEY MUST SATISFY. A flag is a usage
    # error like any other: `--pr-window-min 1e300` raised `OverflowError: timestamp out of range`
    # inside the collector — a traceback, no verdicts, exit 1 (the code that means "a check FAILed").
    NUMERIC_KNOBS = ("window_s", "pr_window_s", "queue_stale_s", "mem_floor_mb", "disk_floor_gb",
                     "pool_threshold", "rest_probe_max", "respawn_timeout_s")

    FIELDS = (
        "window_s",
        "pr_window_s",
        "queue_stale_s",
        "mem_floor_mb",
        "disk_floor_gb",
        "pool_threshold",
        "rest_probe_max",
        "respawn_timeout_s",
        "label",
        "repo",
        "o_dir",
        "log_path",
        "box",
        "controller_ws",
        "controller_name",
        "state_path",
    )

    def __init__(self, **kw):
        for k, v in self.DEFAULTS.items():
            setattr(self, k, v)
        # Not a fixture input: how much log this process reads. Bounded on purpose — the log on a
        # busy box is hundreds of MB and an unbounded read is itself an outage.
        self.log_tail_lines = 6000
        for k in self.FIELDS:
            if k in kw and kw[k] is not None:
                setattr(self, k, kw[k])
        # Coerce numerics: a fixture is JSON and JSON has no float width contract.
        for k in ("window_s", "pr_window_s", "queue_stale_s", "mem_floor_mb", "disk_floor_gb",
                  "respawn_timeout_s"):
            setattr(self, k, float(getattr(self, k)))
        self.pool_threshold = int(self.pool_threshold)
        self.rest_probe_max = int(self.rest_probe_max)

    def controller_paths(self):
        """The controller script(s) for THIS cell: `$O/orch-loop.sh`, plus the harness copy if a
        deployed layout keeps one. Derived from the same `$O` the log and heartbeat come from — a
        separate notion of "where the controller lives" is how two verdicts drift apart."""
        if not self.o_dir:
            return []           # not configured: no path to compare a rejected row against
        out = [os.path.join(self.o_dir, "orch-loop.sh")]
        harness = os.path.join(self.o_dir, "orchestrator-harness", "orch-loop.sh")
        if harness not in out:
            out.append(harness)
        return out

    def as_json(self):
        """The inputs a report must disclose to EXPLAIN ITS OWN VERDICT.

        ⛔ Not "the subset a fixture may declare" (that was wrong in both directions: it omitted
        `queue_stale_s`, which decides STATE_FROZEN, and `cfg_from_dict` accepts every default). Two
        runs with `--queue-stale-min 90` and `--queue-stale-min 0` emitted byte-identical config
        blocks while grading the same record differently.
        """
        return {
            "window_s": self.window_s,
            "queue_stale_s": self.queue_stale_s,
            "pr_window_s": self.pr_window_s,
            "mem_floor_mb": self.mem_floor_mb,
            "disk_floor_gb": self.disk_floor_gb,
            "pool_threshold": self.pool_threshold,
            "rest_probe_max": self.rest_probe_max,
            # decides whether a reported respawn "took" (advance within this budget)
            "respawn_timeout_s": self.respawn_timeout_s,
            "label": self.label,
            "repo": self.repo,
            "box": self.box,
            # ⛔ WHICH CELL was read is part of explaining a verdict: `--o` is how a cell is named,
            # and two runs against different cells emitted byte-identical config blocks. These are
            # disclosed from the INSTANCE (their defaults are None), which is why a
            # `isinstance(v, (int, float, str))` loop over DEFAULTS could never require them.
            "o_dir": self.o_dir,
            "log_path": self.log_path,
            "state_path": self.state_path,
            "controller_ws": self.controller_ws,
            "controller_name": self.controller_name,
        }


def cfg_from_dict(d):
    """Build a Cfg from a fixture's `config` block (unknown keys ignored, defaults filled)."""
    return Cfg(**{k: v for k, v in (d or {}).items() if k in Cfg.DEFAULTS})


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Verdict
# ════════════════════════════════════════════════════════════════════════════════════════════════


class Verdict(object):
    """One check's outcome.

    `variant` is the machine id of the SHAPE that produced it (`CONTROLLER_ABSENT`, `LOG_SILENT`,
    `NO_DISPATCH`, …). It is what the notifier de-duplicates on: the state is the shape, never the
    numbers, or every new log line would be a new "state change" and the alert would be noise.
    """

    __slots__ = ("name", "status", "variant", "evidence", "detail")

    def __init__(self, name, status, variant, evidence, detail=""):
        assert status in (PASS, FAIL, INCONCLUSIVE), status
        self.name = name
        self.status = status
        self.variant = variant
        self.evidence = evidence            # the log line / numbers / timestamps, verbatim
        self.detail = detail                # one line of "what this means"

    @property
    def key(self):
        """The de-duplication key, WITHOUT the box (the notifier scopes by box itself)."""
        return "%s|%s" % (self.name, self.variant)

    def as_json(self):
        return {
            "check": self.name,
            "status": self.status,
            "variant": self.variant,
            "evidence": self.evidence,
            "detail": self.detail,
            "section": ORIENTATION.get(self.name, ""),
            "next": NEXT_COMMAND.get(self.name, ""),
        }

    def __repr__(self):
        return "Verdict(%s, %s, %s)" % (self.name, self.status, self.variant)


def V(name, status, variant, evidence, detail=""):
    return Verdict(name, status, variant, evidence, detail)


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Log parsing — pure. The orchestrator's log IS the fleet's outcome ledger.
# ════════════════════════════════════════════════════════════════════════════════════════════════

# A cycle header. MEASURED: the loop writes TWO date formats, in the same log
#   === Sun Oct 18 07:47:44 EST 2026 load=40 lanes=2 backlog=47 queue=READ(223)(9m) gh=… ===
#   === Sun 18 Oct 2026 07:36:20 EST load=40 lanes=0 backlog=42 queue=READ(237)(6h) ===
# so the outer shape is matched loosely and the date is taken by two explicit patterns. An
# unparseable date makes every age derived from it UNKNOWN, which the predicates treat as "not
# fresh" — never as fresh (a wrong age is worse than an unknown one; see parse_cycle_ts).
RE_HEADER = re.compile(r"^=== +(?P<body>.+?) *===\s*$")
# Sun Oct 18 07:47:44 EST 2026
RE_TS_A = re.compile(r"^(?P<dow>[A-Z][a-z]{2}) (?P<mon>[A-Z][a-z]{2}) +(?P<day>\d{1,2}) "
                     r"(?P<hms>\d\d:\d\d:\d\d) (?P<tz>\S+) (?P<year>\d{4})\b")
# Sun 18 Oct 2026 07:36:20 EST
RE_TS_B = re.compile(r"^(?P<dow>[A-Z][a-z]{2}) +(?P<day>\d{1,2}) (?P<mon>[A-Z][a-z]{2}) "
                     r"(?P<year>\d{4}) (?P<hms>\d\d:\d\d:\d\d) (?P<tz>\S+)\b")
RE_LOAD = re.compile(r"\bload=(?P<n>\d+)")
RE_LANES = re.compile(r"\blanes=(?P<n>\d+)")
RE_BACKLOG = re.compile(r"\bbacklog=(?P<n>\d+)")
RE_QUEUE = re.compile(r"\bqueue=(?P<tok>\S+)")

RE_DISPATCH_OK = re.compile(r"^\[dispatch\] load=(?P<load>\d+) lanes=(?P<lanes>\d+) -> (?P<issues>[0-9 ]+)\s*$")
# ⛔ THE BATCH LINE IS AN INTENT, NOT THE OUTCOME. `orch-loop.sh` echoes `[dispatch] load=… -> N` and
# only THEN calls `dispatch-merge.sh`, whose spawn can fail with its own lines and produce no lane at
# all: `#N: worktree add failed (branch exists?) — skipping`, or — the dangerous one — NOTHING, when
# `tmux new-session` fails (the `&& echo "#$N: lane-$N (implement+PR)"` has no else, so a dead tmux
# server, a stale `chain-$N` session or a full session table prints only the failed chain line). The
# disambiguating lines are in the same 6000-line tail and were never parsed, so `work_dispatched` —
# "the outcome that matters most" — graded an intention and read PASS while nothing was spawned.
# ⛔ THE LINE CARRIES A DISCLOSURE, AND IT IS NOT OPTIONAL AT THE EMITTER (#2209/#2216). Measured at
# `scripts/orchestrator-harness/dispatch-merge.sh:105,107` — the ONE emitter of these lines:
#     echo "#$N: lane-$N (implement+PR, launcher=$_lan)$_hd"          # started
#     echo "#$N: lane-$N NOT spawned (launcher=$_lan)$_hd"            # spawn refused
# so the pre-#2209 literal `(implement+PR)` matched NOTHING a live box writes: `ok` stayed fresh,
# `started` stayed None, and `work_dispatched` abstained (DISPATCH_UNCONFIRMED) on every healthy
# cycle while the FAIL arm that exists for a silently-refused spawn was unreachable. Both shapes are
# accepted here (the disclosure is `${…}`-conditional at the emitter, so the bare form is still
# legal), and the reasoning is derived from the producer in the suite — a hand-copied literal that
# drifts is the defect this pin exists to prevent.
RE_LANE_STARTED = re.compile(
    r"^#(?P<issue>\d+): lane-(?P<lane>\d+) \(implement\+PR(?:, [^)]*)?\)(?: \[[^\]]*\])?\s*$")
RE_LANE_FAILED = re.compile(
    r"^#(?P<issue>\d+): (?P<reason>worktree add failed[^\n]*|lane-\d+ NOT spawned[^\n]*|chain-\d+ could NOT be started[^\n]*)\s*$")
# ⛔ The refusal line has TWO measured shapes, and the second one was being dropped entirely:
#   [dispatch] #4725 NOT dispatched — could not build claim commit          (orch-loop.sh:1608-1644)
#   [dispatch] #1620 NOT dispatched (claim infra error) — …                  (orch-loop.sh:1620)
# so the reason is captured as EVERYTHING after `NOT dispatched` and cleaned in code rather than
# being forced through one literal separator. A parenthetical form not matched here is a refusal the
# canary silently under-counts — which is the "a PASS that hides a degradation" defect.
RE_DISPATCH_REFUSED = re.compile(r"^\[dispatch\] #(?P<issue>\d+) NOT dispatched\b(?P<rest>.*)$")
RE_REFUSAL_LEAD = re.compile(r"^\s*(?:\((?P<paren>[^)]*)\)\s*)?(?:[—–-]\s*)?(?P<reason>.*)$")
RE_DISPATCH_EMPTY = re.compile(r"^\[dispatch\] backlog empty queue=(?P<tok>\S+)\s*$")
# ⛔ The emitter writes `[dispatch] skipped (<why>) lanes=<n> workers=<n>` (orch-loop.sh:1649), so a
# regex anchored at `)$` matched NOTHING in the real log (measured: 223 skipped lines in a 6000-line
# tail, 0 parsed). The trailing counters are optional so both the live line and a bare form parse.
RE_DISPATCH_SKIPPED = re.compile(r"^\[dispatch\] skipped \((?P<why>.*)\)"
                                 r"(?:\s+lanes=\S+\s+workers=\S+)?\s*$")
RE_ARMED = re.compile(r"^#(?P<pr>\d+) auto-armed\s*$")
RE_RAILED = re.compile(r"^#(?P<pr>\d+) PENDING \(rail mode")
# ⛔ THE LOG NAMES ITS OWN REPO, AND THE DECISIONS IN IT BELONG TO THAT REPO. `armed`/`railed` were
# matched to PRs by NUMBER alone, never compared with `--repo`: measured on this Mac, the controller
# log names daniel-ospina/tortoise 972 times and daniel-ospina/agent-infra zero times, its plist says
# OR=tortoise, and `--repo agent-infra` still read PASS/LANDERS_ARMED off tortoise's rail line (mirror
# direction: a false LANDER_EXPIRED). Same family as the cross-batch spawn and the cross-cell census.
RE_LOG_REPO = re.compile(r"^(?:\[req\]|\[authority\])\s+(?P<repo>[\w.-]+/[\w.-]+):")

# The refresh's own vocabulary (orch-loop.sh `queue_state_token`). One vocabulary, parsed not
# re-invented: EMPTY / READ(n) / PARTIAL(<labels>) / UNREADABLE / UNKNOWN.
RE_QUEUE_KIND = re.compile(r"^(?P<kind>EMPTY|UNREADABLE|UNKNOWN|READ\((?P<n>\d+)\)|PARTIAL\((?P<part>[^)]*)\))")
RE_AGE_SUFFIX = re.compile(r"\((?P<age>\d+)(?P<unit>[smh])\)")

MONTHS = {
    "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
    "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
}
DOW = {"Mon": 0, "Tue": 1, "Wed": 2, "Thu": 3, "Fri": 4, "Sat": 5, "Sun": 6}


# Zone abbreviations the loop's `date` can print, as SECONDS EAST OF UTC. ⛔ ONLY TOKENS THAT CANNOT
# COLLIDE ARE HERE, and a token that is not here is NOT guessed at — it falls back to the local-time
# reading. Deliberately ABSENT because they are ambiguous: `IST` (Irish/Indian/Israel), `BST`
# (British Summer / Bangladesh Standard), `AST` (Atlantic / Arabia Standard). A wrong offset is worse
# than the fallback: mapping one of those to the wrong reading makes a header hours off, `_age_of`
# answers UNKNOWN, and the check is a permanent false red.
# ⛔ `CST`/`CDT` ARE KEPT, AND THE AMBIGUITY IS STATED RATHER THAN HIDDEN: they are read as US
# Central (this fleet's cell prints `CST`). A cell that prints `CST` meaning UTC+8 — China Standard —
# must set `TZ` to a numeric form, because the local-time fallback would be wrong for a REMOTE box and
# the table would be wrong for this one. Naming that here is how the adopter finds it before the
# research has to rediscover it.
TZ_OFFSETS = {
    "Z": 0, "UT": 0, "UTC": 0, "GMT": 0,
    "EST": -18000, "EDT": -14400, "CST": -21600, "CDT": -18000,
    "MST": -25200, "MDT": -21600, "PST": -28800, "PDT": -25200,
    "AKST": -32400, "AKDT": -28800, "HST": -36000,
    "NST": -12600, "NDT": -9000,
    "WET": 0, "WEST": 3600, "CET": 3600, "CEST": 7200,
    "EET": 7200, "EEST": 10800, "MSK": 10800,
    "JST": 32400, "KST": 32400, "SGT": 28800, "HKT": 28800,
    "AWST": 28800, "ACST": 34200, "ACDT": 37800, "AEST": 36000, "AEDT": 39600,
    "NZST": 43200, "NZDT": 46800,
}


def tz_offset_s(tok):
    """Seconds east of UTC for a header's zone token, or None when it is not understood.

    ⛔ THE TOKEN USED TO BE MATCHED AND THROWN AWAY, with the rest read as LOCAL time. That is only
    correct while every cell shares the canary's zone: a PST cell read from an EST box reported a
    5-minute-old event as 4h05m old, so its `#N auto-armed` line fell out of the window and a green
    ARMED PR read LANDER_MISSING (and a fresh cycle read NO_REFRESH). Neither direction is safe, so
    the token is converted when it is known and the local-time reading is kept only as a fallback.

    Numeric forms are accepted too (`+0200`, `-05:00`, `+02`), because a `date` with a format string
    prints those instead of a name.
    """
    t = (tok or "").strip().upper()
    if not t:
        return None
    if t in TZ_OFFSETS:
        return TZ_OFFSETS[t]
    m = re.match(r"^(?P<sign>[+-])(?P<h>\d{1,2}):?(?P<m>\d{2})?$", t)
    if not m:
        return None
    off = int(m.group("h")) * 3600 + int(m.group("m") or 0) * 60
    return -off if m.group("sign") == "-" else off


def parse_cycle_ts(ts):
    """'Sun Oct 18 07:47:44 EST 2026' → epoch seconds, or None. Both measured formats accepted.

    The timezone token IS USED: a known abbreviation (or a numeric offset) yields an ABSOLUTE epoch,
    so a cell's age is the same however the canary's own clock is set. An unknown token falls back to
    the old local-time reading — the writer is a `date` on the box, so local time is the fallback that
    matches the same-zone case, and guessing at an unrecognised name would be worse than the fallback.
    """
    if not ts:
        return None
    s = str(ts).strip()
    m = RE_TS_A.match(s) or RE_TS_B.match(s)
    if not m:
        return None
    gd = m.groupdict()
    if gd["mon"] not in MONTHS or gd["dow"] not in DOW:
        return None
    try:
        hh, mm, ss = [int(x) for x in gd["hms"].split(":")]
        struct = (int(gd["year"]), MONTHS[gd["mon"]], int(gd["day"]), hh, mm, ss, 0, 1, -1)
        off = tz_offset_s(gd.get("tz"))
        if off is not None:
            return calendar.timegm(struct) - off
        return time.mktime(struct)
    except Exception:
        return None


def parse_queue_token(tok):
    """'READ(223)(9m)' → {'kind':'READ', 'pool':223, 'token_age_s':540, 'raw':'READ(223)(9m)'}."""
    out = {"kind": "UNPARSEABLE", "pool": None, "token_age_s": None, "raw": tok, "partial": None}
    if not tok:
        return out
    m = RE_QUEUE_KIND.match(str(tok).strip())
    if not m:
        return out
    kind = m.group("kind")
    if kind.startswith("READ("):
        out["kind"] = "READ"
        out["pool"] = int(m.group("n"))
    elif kind.startswith("PARTIAL("):
        out["kind"] = "PARTIAL"
        out["partial"] = m.group("part")
    else:
        out["kind"] = kind
    a = RE_AGE_SUFFIX.search(str(tok), m.end())
    if a:
        mult = {"s": 1, "m": 60, "h": 3600}[a.group("unit")]
        out["token_age_s"] = float(a.group("age")) * mult
    return out


def parse_log(lines, now=None):
    """Turn log lines into the event ledger the predicates read.

    Every event inherits the timestamp of the ENCLOSING CYCLE HEADER. The orchestrator prints no
    per-line timestamp, and a `[dispatch]` line is written a few seconds after its header at most,
    so header inheritance is the honest bound — and it is stated here rather than assumed
    silently, because an age that is quietly wrong is how a stale line reads as fresh.

    When `now` is None the events carry no `age_s` field at all (fixtures precompute ages; they do
    not get a clock).
    """
    ev = {
        "headers": [],
        "dispatch_ok": [],
        "dispatch_refused": [],
        "dispatch_empty": [],
        "dispatch_skipped": [],
        "armed": [],
        "railed": [],
        "lane_started": [],
        "lane_failed": [],
        "repo": [],
        "unparsed_headers": 0,
    }
    cur = None  # epoch of the enclosing header, or None when the header was unparseable
    for raw in lines:
        line = raw.rstrip("\n")
        m = RE_HEADER.match(line)
        if m:
            body = m.group("body")
            ts = parse_ts_field(body)
            if ts is None:
                ev["unparsed_headers"] += 1
                cur = None
                continue
            cur = ts
            rest = _header_rest(body)
            qm = RE_QUEUE.search(rest)
            rec = {
                "raw": line.strip(),
                "ts": ts,
                "queue_token": qm.group("tok") if qm else "",
                "backlog": _int_field(RE_BACKLOG, rest),
                "lanes": _int_field(RE_LANES, rest),
                "load": _int_field(RE_LOAD, rest),
            }
            ev["headers"].append(rec)
            continue
        for bucket, rx in (
            ("dispatch_ok", RE_DISPATCH_OK),
            ("dispatch_refused", RE_DISPATCH_REFUSED),
            ("dispatch_empty", RE_DISPATCH_EMPTY),
            ("dispatch_skipped", RE_DISPATCH_SKIPPED),
            ("armed", RE_ARMED),
            ("railed", RE_RAILED),
            ("lane_started", RE_LANE_STARTED),
            ("repo", RE_LOG_REPO),
            ("lane_failed", RE_LANE_FAILED),
        ):
            mm = rx.match(line)
            if mm:
                rec = {"raw": line.strip(), "ts": cur}
                gd = mm.groupdict()
                gd.pop("rest", None)
                for k, v in gd.items():
                    if v is None:
                        continue
                    if k == "issues":
                        rec["issues"] = [int(x) for x in v.split()]
                        rec["issue_count"] = len(rec["issues"])
                    elif re.match(r"^\d+$", str(v)):
                        rec[k] = int(v)
                    else:
                        rec[k] = v
                if bucket == "dispatch_refused":
                    # Keep the reason readable whichever separator form the emitter used, and keep
                    # the parenthetical ("claim infra error") as part of it — that text is what
                    # tells an operator WHICH half of the claim path broke.
                    lead = RE_REFUSAL_LEAD.match(mm.group("rest") or "")
                    paren = (lead.group("paren") or "").strip() if lead else ""
                    reason = (lead.group("reason") or "").strip() if lead else ""
                    if paren:
                        reason = ("(%s) %s" % (paren, reason)).strip()
                    rec["reason"] = reason or "(no reason printed)"
                ev[bucket].append(rec)
                break
    if now is not None:
        for bucket in ("headers", "dispatch_ok", "dispatch_refused", "dispatch_empty",
                       "dispatch_skipped", "armed", "railed", "lane_started", "lane_failed",
                       "repo"):
            for rec in ev.get(bucket) or []:
                rec["age_s"] = _age_of(now, rec.get("ts"))
    return ev


# A wall clock in the future is not a fresh event. `parse_cycle_ts` drops the tz token and reads the
# header as LOCAL time, so a `--live --box` run against a cell in another timezone produces a NEGATIVE
# age when the cell is ahead of the canary's clock (a UTC cell read from UTC-5 yields -5h for an event
# 30 minutes old). A negative age passes a `age > window` staleness test and reads GREEN. Anything more
# than this tolerance in the future is UNKNOWN, not fresh.
CLOCK_SKEW_TOLERANCE_S = 120.0


def _age_of(now, ts):
    if ts is None:
        return None
    age = now - ts
    return None if age < -CLOCK_SKEW_TOLERANCE_S else age


def parse_stat_mtime(out):
    """The epoch from `stat`'s output, for BOTH shapes:
         BSD:  `stat -f %m FILE`      -> `1792328709`
         GNU:  `stat -c %Y FILE`      -> `1792328709`
         GNU with `-f` (filesystem mode, which DOES NOT FAIL) -> a multi-line block whose last line
              is the epoch. Reading the FIRST line of that block yielded `  File: "…"`.
    The last non-empty line is the only position correct for all three.
    """
    lines = [ln.strip() for ln in str(out or "").splitlines() if ln.strip()]
    if not lines:
        return None
    last = lines[-1]
    return int(last) if re.match(r"^\d{9,}$", last) else None


def parse_ts_field(ts):
    """The header timestamp, as `parse_cycle_ts` reads it (one implementation, one call site)."""
    return parse_cycle_ts(ts)


def _header_rest(body):
    """Drop the leading date from a header body, keeping the key=value tail."""
    m = RE_TS_A.match(body) or RE_TS_B.match(body)
    return body[m.end():] if m else body


def _int_field(rx, text):
    m = rx.search(text or "")
    return int(m.group("n")) if m else None


def newest_with_age(events, window_s, require_age=True):
    """The newest event that is FRESH (age <= window) — or None.

    `require_age` is what separates "no such outcome happened" from "we cannot tell": an event whose
    age is unknown is not fresh, and the callers distinguish the two when they build their verdict.
    """
    best = None
    for e in events or []:
        raw_age = e.get("age_s")
        age = raw_age if _is_age(raw_age) else None
        if require_age and age is None:
            continue
        if age is not None and age > window_s:
            continue
        best_age = best.get("age_s") if best is not None else None
        best_age = best_age if _is_age(best_age) else None
        if best is None or (age is not None and (best_age is None or age < best_age)):
            best = e
    return best


def newest(events):
    """The newest event by age, fresh or not (for EVIDENCE about a stale thing)."""
    best = None
    for e in events or []:
        raw_age = e.get("age_s")
        age = raw_age if _is_age(raw_age) else None
        if best is None:
            best = e
            continue
        if age is None:
            continue
        best_age = best.get("age_s") if _is_age(best.get("age_s")) else None
        if best_age is None or age < best_age:
            best = e
    return best


# Programs whose ARGUMENTS are a search pattern, not a process. A row starting with one of these
# cannot testify that the named program is running — it testifies that someone looked for it.
# ⛔ "unscoped `pkill`" is a FORBIDDEN form in this file (the suite scans for the token), so the
# search-tool family is spelled without it: `pgrep` covers the same diagnostic, and a row that runs
# an unscoped killer is not something this predicate needs to name.
_INSPECTORS = frozenset(("pgrep", "pidof", "ps", "grep", "egrep", "fgrep", "rg", "ag",
                         "ack", "awk", "sed", "find", "xargs", "watch", "tail", "head", "cat",
                         "less", "more", "vim", "nvim", "nano", "emacs", "code", "open", "echo",
                         "printf", "man", "which", "type", "command", "lsof", "lesspipe"))


def _names_our_program(rows, paths=(), names=()):
    """The rejected rows whose COMMAND LINE names the program we are looking for.

    ⛔ EXACT TOKENS, NOT SUBSTRINGS. A substring test counted the operator's own `tail -f
    ~/.cmux/cmux-tui.out` as the daemon, and a bare `orch-loop.sh` basename counted a leaked fixture
    from another directory as THIS cell's controller — so the "a rejected row names it, abstain"
    guard fired on evidence that named a different program entirely.
    """
    out = []
    want = [x for x in paths if x]
    for r in rows:
        if not isinstance(r, dict):
            continue
        toks = str(r.get("cmd") or "").split()
        # ⛔ A ROW WHOSE PROGRAM IS A SEARCH OR VIEW TOOL NAMES THE PATH, NOT THE PROCESS — and the
        # paths branch is the one the CONTROLLER census uses, so `cat /O/orch-loop.sh`,
        # `vim /O/orch-loop.sh` and `grep -n cycle /O/orch-loop.sh` all counted as "a rejected row
        # names this cell's controller". A genuinely absent controller then read
        # `CENSUS_NEAR_MISS` and `attempt_respawn` refused — for as long as anyone had the script
        # open, which is exactly the operator behaviour this rule exists to keep honest.
        if toks and os.path.basename(toks[0]) in _INSPECTORS:
            continue
        hit = any(t in want for t in toks)
        if not hit and names:
            # The inspector guard is ABOVE, shared by both branches: `pgrep -fl cmux-tui` is this
            # tool's own documented next command, and a `cat`/`vim`/`grep` of the controller script
            # names the PATH, not a running program. A row that really NAMES the program — behind
            # `nice`, or an interpreter — still counts.
            hit = any(os.path.basename(t) in names for t in toks)
        if hit:
            out.append(r)
    return out


def _near_ours_txt(rows):
    """Render the rejected rows that NAME this cell's controller — a different claim from `_near_txt`,
    whose every entry is `not this cell's controller`."""
    if not rows:
        return "(none)"
    return "; ".join("pid %s: %s" % (r.get("pid"), str(r.get("cmd") or "")[:160]) for r in rows[:4])


def _near_txt(ctrl):
    """The rejected processes, with the reason they were rejected.

    The census SCOPES to this cell's controller path; without this line "no controller" is
    indistinguishable from "nothing was there to see", which is the artifact the scoping fix exists to
    end — and the module's own docstring promises the reader can see what was rejected.
    """
    lines = []
    scoped = ctrl.get("scoped_to") or []
    if scoped:
        lines.append("scoped to: %s" % ", ".join(scoped))
    near = ctrl.get("near_misses") or []
    if near:
        lines.append("rejected (not this cell's controller):")
        for r in near[:6]:
            lines.append("  pid %s: %s" % (r.get("pid"), (r.get("cmd") or "")[:120]))
    return "\n".join(lines)


def _age_txt(age):
    # ⛔ THE ONE PLACE EVERY AGE IS PRINTED, SO THE RULE LIVES HERE. `_age_txt(True)` formatted a
    # boolean as "1s ago": the verdict refused the unread age and the EVIDENCE in the same block —
    # the bytes `compose_message` puts in the controller's inbox — asserted a measured one second.
    if not _is_age(age):
        return "age UNKNOWN"
    if age < 120:
        return "%.0fs ago" % age
    if age < 7200:
        return "%.0fm ago" % (age / 60.0)
    if age < 172800:
        return "%.1fh ago" % (age / 3600.0)
    return "%.1fd ago" % (age / 86400.0)


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Check 1 — controller cycling
# ════════════════════════════════════════════════════════════════════════════════════════════════


def check_controller_cycling(f, c):
    ctrl = (f.get("controller") or {})
    # ⛔ AN ABSENT `pids` KEY IS A MISSING READ, NOT AN EMPTY PROCESS TABLE. `or []` collapsed the
    # two, and `CONTROLLER_ABSENT` is the one verdict that fires `launchctl kickstart -k`: an injected
    # or partially-written facts payload (`{"controller": {"ok": true}}`, or a `--facts` file derived
    # from a fixture) reached CONTROLLER_ABSENT with the process table never read, and the
    # re-measure guard could not stop it because the fingerprint read the same broken probe. A
    # measured ZERO is a list (`[]`); anything else is unread. Allow-list polarity, as in
    # `pane_daemon`/`landers`.
    raw_pids = ctrl.get("pids")
    if ctrl.get("ok") is True and not isinstance(raw_pids, list):
        return V("controller_cycling", INCONCLUSIVE, "PROCESS_TABLE_UNREADABLE",
                 "controller probe: ok=True but no `pids` LIST — the process table was not "
                 "returned (%r)" % (raw_pids,),
                 "an absent process list is not a census of zero: whether a controller is running "
                 "cannot be told from it, and this is the one verdict that respawns. Not green, "
                 "and NOT an absence.")
    pids = raw_pids if isinstance(raw_pids, list) else []
    launchd = f.get("launchd") or {}
    log = f.get("log") or {}
    hb = f.get("heartbeat") or {}
    win = c.window_s

    pid_txt = ", ".join(str(p.get("pid")) for p in pids) if pids else "none"
    if len(pids) > 1:
        # More than one match is REPORTED, not hidden: the deepest is the controller, and a second
        # one is either a cycle handoff or a lock violation. Either way the reader sees the count.
        pid_txt = "%s (deepest first; %d matched)" % (pid_txt, len(pids))
    lc = launchd.get("label") or c.label
    lc_txt = _launchd_txt(launchd)
    # ⛔ A BOOL IS NOT AN AGE HERE EITHER. `log_age > win` is False for `True` (one second), so the
    # "alive but useless" FAIL was unreachable on an injected/partial payload, and the next arm
    # printed the boolean as a measured "(1s ago)". A non-number is an UNREAD age: the refusal to
    # tell "alive but useless" from "alive and working" is the abstention below, not a verdict.
    _raw_log_age = log.get("age_s")
    log_age = _raw_log_age if _is_age(_raw_log_age) else None
    log_txt = "%s mtime %s (%s)" % (
        log.get("path") or "<log>",
        log.get("mtime_iso") or "?",
        _age_txt(log_age),
    )
    hb_txt = "heartbeat %s" % (_age_txt(hb.get("age_s")) if _is_age(hb.get("age_s"))
                              else "absent/unreadable")

    # ── ABSTAIN: the process table itself could not be read ──────────────────────────────
    # ⛔ ALLOW-LIST POLARITY, like every other read in this file: an ABSENT `ok` is a MISSING READ,
    # not a successful one. `is False` made `{"controller": {}}` (a collector regression, or an
    # injected facts dict) read as an EMPTY PROCESS TABLE, which is the one state that respawns.
    if ctrl.get("ok") is not True:
        return V("controller_cycling", INCONCLUSIVE, "PROCESS_TABLE_UNREADABLE",
                 "process table read FAILED (%s)\nlaunchd %s: %s\n%s"
                 % (ctrl.get("error") or "no error recorded", lc, lc_txt, log_txt),
                 "whether a controller exists is UNKNOWN — the `ps` read did not happen. This is "
                 "NOT absence, and absence is the only state that respawns, so an unreadable "
                 "table must never reach it. Not green.")

    # ── ABSENT: no process AND launchd has no pid ────────────────────────────────────────────
    # ⛔ THE SCOPED CENSUS'S ZERO IS NOT ABSENCE — IN EITHER ARM. The guard below was gated on
    # launchd holding a pid, so a cell whose launchd reports NO pid (or whose launchctl read failed)
    # still reached FAIL/CONTROLLER_ABSENT — "no controller exists at all", a RESPAWN TRIGGER — over a
    # census that had just rejected `nice -n 5 /bin/bash …/orch-loop.sh`. Whether the cell uses
    # launchd decided the verdict, not whether the controller exists. The check is hoisted above BOTH
    # absence arms, and the rejected row is quoted as `names the controller` (not "not this cell's
    # controller", which is what most rejections are).
    near = ctrl.get("near_misses") or []
    # ⛔ THE PAYLOAD'S OWN `scoped_to` IS THE AUTHORITY when it carries one: it is the path list the
    # census actually applied, so a rejected row can be compared against what was really scoped
    # rather than against a config the payload may not have used.
    _paths = [p for p in (ctrl.get("scoped_to") or c.controller_paths()) if p]
    near_ours = _names_our_program(near, paths=_paths,
                                  names=() if _paths else ("orch-loop.sh",))
    if not pids and near_ours:
        return V("controller_cycling", INCONCLUSIVE, "CENSUS_NEAR_MISS",
                 "processes matching THIS cell's orch-loop.sh: 0\n"
                 "REJECTED rows that NAME the controller: %s\n"
                 "launchd %s: %s\n%s" % (_near_ours_txt(near_ours), lc, lc_txt, log_txt),
                 "the SCOPED census matched nothing, but it REJECTED a process whose command names "
                 "this cell's orch-loop.sh — so 'no controller exists' is not established, and a "
                 "canary that respawns on an unestablished absence can kill a live controller. Not "
                 "green, and NOT a respawn trigger.")
    if not pids and launchd.get("pid") is None:
        return V("controller_cycling", FAIL, "CONTROLLER_ABSENT",
                 "processes matching THIS cell's orch-loop.sh: 0\n"
                 "%s\n"
                 "launchd %s: %s\n"
                 "%s\n"
                 "%s\n"
                 "%s" % (_near_txt(ctrl) or "scoped to: (not configured)",
                         lc, lc_txt, log_txt, hb_txt, _last_header_txt(f)),
                 "no controller exists at all: nothing will dispatch, merge or report. A respawn "
                 "is attempted (this is the ONLY state that respawns).")

    # ── launchd claims a pid but nothing in the process table matches it ─────────────────────
    # (the scoped-census guard above covers this arm too — it is hoisted above both)
    if not pids and launchd.get("pid") is not None:
        return V("controller_cycling", FAIL, "LAUNCHD_PID_UNRESOLVED",
                 "processes matching THIS cell's orch-loop.sh: 0\n"
                 "%s\n"
                 "launchd %s: %s\n"
                 "%s" % (_near_txt(ctrl) or "scoped to: (not configured)", lc, lc_txt, log_txt),
                 "launchd believes a controller is running but no such process exists — a "
                 "recycled pid or a crashed exec. The pid is not evidence; the process is.")

    # ── the pid exists; the question is whether it is DOING anything ──────────────────────────
    if log.get("exists") is False:
        return V("controller_cycling", FAIL, "LOG_MISSING",
                 "controller pid(s): %s\nlaunchd %s: %s\nlog: %s does not exist"
                 % (pid_txt, lc, lc_txt, log.get("path")),
                 "a controller with no log has produced no evidence of a single cycle.")
    if log_age is None:
        # The log EXISTS but its age could not be read (EACCES/TCC, a timed-out probe). That is an
        # abstention, not absence: a failed read is not a claim about the world.
        return V("controller_cycling", INCONCLUSIVE, "LOG_UNREADABLE",
                 "controller pid(s): %s\nlaunchd %s: %s\nlog: %s exists but could not be stat'ed "
                 "(%s)" % (pid_txt, lc, lc_txt, log.get("path"),
                           log.get("error") or "no error recorded"),
                 "the log age is unknown, so 'alive but useless' cannot be told from 'alive and "
                 "working'. Not green.")
    if log_age > win:
        return V("controller_cycling", FAIL, "LOG_SILENT",
                 "controller pid(s): %s IS ALIVE (launchd %s: %s)\n"
                 "%s — frozen for %.0fs, window is %.0fs\n"
                 "%s\n"
                 "%s" % (pid_txt, lc, lc_txt, log_txt, log_age, win, hb_txt, _last_header_txt(f)),
                 "the exact shape of 'alive but useless': a running pid whose log has stopped "
                 "advancing. Nothing is being decided.")

    # ⛔ THE MTIME VERDICT OUTRANKS THE CONTENT ONE. The frozen-log FAIL below is established by
    # `log_age` alone; asking the tail guard first published `INCONCLUSIVE/LOG_UNREADABLE` for a live
    # pid whose log had been frozen for 3h — reporting an unread content where a measured FAIL was
    # available. The abstention belongs to a log that IS moving and whose content nobody read.
    if log.get("tail_ok") is not True:
        # a fresh mtime proves the file is MOVING; it says nothing about WHAT is in it. Without this
        # arm the failed read fell through to LOG_NO_CYCLE — "the log IS advancing, but not by a
        # cycle" — which is a claim about content nobody read.
        return V("controller_cycling", INCONCLUSIVE, "LOG_UNREADABLE",
                 "controller pid(s): %s IS ALIVE (launchd %s: %s)\n"
                 "%s\ntail: %s"
                 % (pid_txt, lc, lc_txt, log_txt,
                    # an ABSENT result is not a failed one, and saying "tail failed" about a payload
                    # that never reported would be the same unmeasured claim one level down
                    log.get("tail_error") if log.get("tail_ok") is False
                    else "result NOT REPORTED by this payload"),
                 "the log's mtime is readable but its CONTENT was not read, so 'no cycle completes' "
                 "cannot be told from 'the tail was refused'. Not green.")
    cycles = [h for h in (f.get("log_events") or {}).get("headers") or []
              if _is_age(h.get("age_s")) and h["age_s"] <= win]
    # ⛔ AN UNPARSEABLE HEADER IS NOT AN ABSENT ONE. `parse_log` counts a header it cannot parse
    # in `unparsed_headers`, and `queue_readable`/`work_dispatched` both abstain on it — while this
    # check graded the same datum FAIL/LOG_NO_CYCLE ("a mid-cycle wedge"), reddening a healthy
    # controller whose log format had merely moved. The parser already carries two timestamp formats
    # (`RE_TS_A`/`RE_TS_B`) because the log changed once; a third would have raised a false alarm on
    # the check an operator reads first.
    unparsed = (f.get("log_events") or {}).get("unparsed_headers") or 0
    if not cycles and unparsed:
        return V("controller_cycling", INCONCLUSIVE, "LOG_FORMAT_UNREAD",
                 "controller pid(s): %s IS ALIVE (launchd %s: %s)\n%s\n%s\n%d cycle header(s) "
                 "present but UNPARSEABLE — the log format moved, so 'no cycle completes' was NOT "
                 "established" % (pid_txt, lc, lc_txt, log_txt, _last_header_txt(f), unparsed),
                 "the log carries %d header(s) this build cannot parse, so a wedge cannot be told "
                 "from a format change. Not green." % unparsed)
    if not cycles:
        # ⛔ A MOVING FILE IS NOT A CYCLE. `cycles` was computed, printed and never graded, so a
        # controller wedged mid-cycle read PASS/CYCLING for as long as anything else appended to the
        # log — `claim-prune` and the `[reap-worker]` lines do, by design. The check's own name is
        # the claim being made, so an empty cycle list refutes it.
        return V("controller_cycling", FAIL, "LOG_NO_CYCLE",
                 "controller pid(s): %s IS ALIVE (launchd %s: %s)\n"
                 "%s\n%s\n0 cycle header(s) inside the %.0fs window — the log IS advancing "
                 "(%.0fs ago), but not by a cycle"
                 % (pid_txt, lc, lc_txt, log_txt, _last_header_txt(f), win, log_age),
                 "the controller's log is moving while no cycle completes: a mid-cycle wedge looks "
                 "exactly like this, and 'a controller cycled' is the outcome this check asserts. A "
                 "pid plus a moving file is not a cycling controller.")
    return V("controller_cycling", PASS, "CYCLING",
             "controller pid(s): %s\nlaunchd %s: %s\n%s\n%s\n%d cycle header(s) inside the %.0fs window"
             % (pid_txt, lc, lc_txt, log_txt, hb_txt, len(cycles), win))


def _launchd_txt(launchd):
    if launchd.get("loaded") is True:
        return "loaded, pid=%s" % (launchd.get("pid") if launchd.get("pid") is not None else "none")
    if launchd.get("loaded") is False:
        return "NOT loaded" + ((" (%s)" % launchd["error"]) if launchd.get("error") else "")
    return "could not be consulted" + ((" (%s)" % launchd["error"]) if launchd.get("error") else "")


def _last_header_txt(f):
    h = newest(((f.get("log_events") or {}).get("headers")) or [])
    if not h:
        return "last cycle header: NONE in the parsed log tail"
    return "last cycle header (%s): %s" % (_age_txt(h.get("age_s")), h.get("raw"))


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Check 2 — the refresh's verdict is READABLE
# ════════════════════════════════════════════════════════════════════════════════════════════════


def check_queue_readable(f, c):
    events = f.get("log_events") or {}
    win = c.window_s
    hdr = newest_with_age(events.get("headers"), win)
    if hdr is None:
        allh = newest(events.get("headers"))
        unparsed = events.get("unparsed_headers") or 0
        return V("queue_readable", INCONCLUSIVE, "NO_REFRESH",
                 "no cycle header inside the %.0fs window\nlast: %s%s"
                 % (win, allh.get("raw") if allh else "none in the parsed log tail",
                    # ⛔ COUNTED AND NEVER READ. The parser counts a header it cannot read, and the
                    # evidence then said "none in the parsed log tail" while the log held N of them —
                    # a false statement about the world that reads exactly like "the loop wrote
                    # nothing", which is the artifact the census's near-misses were created to end.
                    ("\n%d header(s) present but UNPARSEABLE — the log format moved" % unparsed)
                    if unparsed else ""),
                 "the refresh did not run in the window, so its verdict cannot be read. Not green.")

    # ⛔ THE AUTHORITATIVE TOKEN, not merely the newest header's: see `authoritative_queue_token`.
    tok, raw_tok, tok_src = authoritative_queue_token(f, hdr)
    state_txt = _queue_state_file_txt(f)
    # ⛔ A FAILED READ OF THE RECORD MAY NOT BE GRADED GREEN THROUGH THE HEADER. The record exists
    # (a readable header token proves the refresh ran and wrote it), so "I could not read it" is a
    # missing read, not a licence for the one-refresh-old header to answer. On a `--box` run the read
    # is a remote `cat` that returns rc 127 on timeout, and EACCES/TCC does the same locally: a
    # permanent false green, which is the direction that must never pass.
    qs_rec = f.get("queue_state") or {}
    if tok_src != "cycle header":
        state_txt += "\nqueue verdict graded from: %s (it is NEWER than the header token %s)" % (
            tok_src, hdr.get("queue_token") or "(absent)")
    backlog = hdr.get("backlog")

    # ⛔ ALLOW-LIST POLARITY: an ABSENT `ok` is a MISSING READ, not a successful one. `is False` let
    # a facts dict with NO `queue_state` key at all grade PASS/READABLE over nothing that was read.
    if qs_rec.get("ok") is not True and tok_src == "cycle header":
        return V("queue_readable", INCONCLUSIVE, "QUEUE_STATE_UNREADABLE",
                 "header: %s\npool token: %s\n%s"
                 % (hdr.get("raw"), raw_tok, state_txt),
                 "the refresh's own record could not be read (%s), so the pool verdict rests on a "
                 "header token that is always one refresh old. A failed read is not a successful "
                 "read. Not green." % (qs_rec.get("error") or "no error recorded"))
    if tok["kind"] == "UNREADABLE":
        return V("queue_readable", FAIL, "QUEUE_UNREADABLE",
                 "header: %s\npool token: %s\n%s\nbacklog=%s"
                 % (hdr.get("raw"), raw_tok, state_txt, backlog),
                 "the pool could not be read at all: the fleet is BLIND, which is not 'nothing to "
                 "do'. A blind box idles exactly like an idle one (#1931).")
    if tok["kind"] in ("UNKNOWN", "UNPARSEABLE"):
        return V("queue_readable", FAIL, "QUEUE_NEVER_READ",
                 "header: %s\npool token: %s (%s)\n%s"
                 % (hdr.get("raw"), raw_tok, "never recorded a read" if tok["kind"] == "UNKNOWN"
                    else "token outside the refresh vocabulary", state_txt),
                 "no pass has ever recorded a pool read. The absence of a measurement is not a "
                 "measurement of emptiness.")
    if tok["kind"] == "PARTIAL":
        return V("queue_readable", FAIL, "QUEUE_PARTIAL",
                 "header: %s\npool token: %s (unread tiers: %s)\n%s"
                 % (hdr.get("raw"), raw_tok, tok.get("partial") or "?", state_txt),
                 "only some priority tiers were read, so the pool is a SUBSET. 'Readable' is not "
                 "established by a partial read.")

    # EMPTY / READ(n): the token is readable. The remaining question is whether an EMPTY BACKLOG is
    # honest given what the refresh itself had just read. `backlog=0` out of a pool of 223 is the
    # #1931 shape — the refresh produced nothing from a pool it read as large. It is reported even
    # though 'every issue is already claimed' is the legitimate way to reach it: the variant names
    # the shape, the evidence carries the pool count and the queue token, and a human can tell the
    # two apart in one read. (Silence is not the safe default here — a blind refresh looks identical.)
    pool = tok.get("pool")
    stale = _graded_stale(f, c, tok_src)
    # ⛔ EMPTINESS IS THE ONE CLAIM A FROZEN READ CANNOT SUPPORT — and an UNKNOWN age supports NO
    # claim at all. This guard used to fire only for EMPTY, so `queue=READ(223)` written without an
    # epoch (the bare token the harness emits when its `$at` field is missing or unparsable) was
    # graded READABLE with the age printed as "UNKNOWN": a refresh that stopped writing hours ago,
    # having lost its epoch, read as current, and `queue_stale_s` — whose whole job is to stop that —
    # could not fire because `_queue_age` answered None. A KNOWN-and-old NON-EMPTY read is still
    # accepted (it does say "readable, n candidates"); an unaged one is not.
    if stale is not None:
        if stale["age_s"] is None:
            return V("queue_readable", INCONCLUSIVE, "STATE_FROZEN", _queue_frozen_txt(f, stale),
                     "the pool reading (%s) carries NO AGE — no epoch in the token, none in "
                     "state/queue-state — so a current read cannot be told from a record frozen "
                     "hours ago. A state record with no age is a stale flag waiting to be read as "
                     "current, and an UNKNOWN age is not a fresh one. Not green." % (raw_tok,))
        if tok["kind"] == "EMPTY":
            return V("queue_readable", INCONCLUSIVE, "STATE_FROZEN", _queue_frozen_txt(f, stale),
                     ("the pool was read as EMPTY %s (limit %.0fs), so 'the pool is empty' is a "
                      "claim about then, not now. Not green." % (
                          _age_txt(stale["age_s"]), stale["limit_s"])))
        # ⛔ GREEN ON A FROZEN REFRESH IS THE #1931 FAILURE WEARING A PASS. A KNOWN-and-old NON-EMPTY
        # read was graded PASS/READABLE ("it does say readable, n candidates"), so a box whose refresh
        # froze three hours ago exited 0 for the WHOLE run while the controller dispatched off a stale
        # `candidates.txt` — constructed and measured: fresh header, `queue=READ(223)(3h)`,
        # `state/queue-state` 3h old → PASS/READABLE, exit 0. The claim is legible now, and it is not
        # a pass: the pool number is a statement about three hours ago.
        return V("queue_readable", INCONCLUSIVE, "READABLE_STALE", _queue_frozen_txt(f, stale),
                 ("the pool was read as %s %s (limit %.0fs): the reading is legible but not "
                  "CURRENT, so 'the last refresh produced a readable verdict' is a claim about %.0fs "
                  "ago. Not green." % (raw_tok, _age_txt(stale["age_s"]), stale["limit_s"],
                                       stale["age_s"])))
    if tok["kind"] == "EMPTY" and backlog is None:
        return V("queue_readable", INCONCLUSIVE, "HEADER_INCOMPLETE",
                 "header: %s has no backlog= field, so 'empty' cannot be checked against it"
                 % hdr.get("raw"),
                 "an incomplete header is not a readable verdict.")
    # ⛔ A BACKLOG AND A POOL FROM DIFFERENT RECORDS ARE NOT A PAIR. `backlog=` and `queue=` are
    # written on ONE header line by ONE cycle, so the header's own pair is consistent; when the graded
    # token comes from the NEWER `state/queue-state` (which carries no backlog), pairing its pool with
    # the header's one-refresh-old backlog compares two refreshes and reports the difference as a
    # defect. The pair is taken from the header, and the state record's own verdict is printed beside
    # it so a human can see when the two disagree.
    pair = parse_queue_token(hdr.get("queue_token") or "")
    pair_pool = pair.get("pool")
    # ⛔ A CURRENT `state/queue-state: EMPTY` SUPERSEDES THE HEADER'S PAIR. The header's `queue=` and
    # `backlog=` are ONE refresh old; when the newer record says the pool is now EMPTY, the header's
    # large pool is superseded too, and grading the header's pair anyway produced
    # `queue_readable FAIL/EMPTY_WITH_LARGE_POOL` beside `work_dispatched PASS/IDLE_EMPTY_POOL` for
    # ONE facts dict — two checks reading one world in opposite directions, with the FAIL's own
    # evidence line saying "graded from: state/queue-state (it is NEWER than the header token)".
    superseded = (tok["kind"] == "EMPTY" and tok_src == "state/queue-state" and stale is None)
    if _is_count(backlog) and backlog == 0 \
            and _is_count(pair_pool) and pair_pool >= c.pool_threshold and not superseded:
        return V("queue_readable", FAIL, "EMPTY_WITH_LARGE_POOL",
                 "header: %s\nbacklog=0 while the SAME header had just READ %d issue(s) "
                 "(threshold %d)\ngraded record: %s (pool %s)\n%s"
                 % (hdr.get("raw"), pair_pool, c.pool_threshold, raw_tok, pool, state_txt),
                 "the refresh produced an EMPTY backlog out of a pool it had just read as large. "
                 "Either the pool read was wrong (a refresh defect, #1931) or every issue is "
                 "already claimed — the evidence above is what tells the two apart.")

    return V("queue_readable", PASS, "READABLE",
             "header: %s\npool token: %s\n%s\nbacklog=%s"
             % (hdr.get("raw"), raw_tok, state_txt, backlog))


def read_queue_state(machine, cfg, now):
    """The refresh's own recorded verdict: `{ok, raw, age_s, path}`.

    Extracted from `collect_live` so the COLLECTOR CONTRACT is testable directly: every defect in
    this record's reading (a failed `cat`, a torn/empty body, a missing epoch) was a green verdict
    that fixtures alone could not reach, because the fixtures supply an already-built dict.
    """
    qs_raw, qs_err = machine.read_file(os.path.join(cfg.o_dir, "state", "queue-state"))
    qs = {"path": os.path.join(cfg.o_dir, "state", "queue-state")}
    if qs_raw is None:
        qs["ok"] = False
        qs["error"] = qs_err
        qs["raw"] = None
    elif not (qs_raw or "").strip():
        # ⛔ A TORN WRITE IS NOT A VERDICT. `read_file` returns ("", None) for `cat` of an EMPTY file
        # (rc 0, no stdout), and `refresh-candidates.sh` writes the record with `>` — truncate first,
        # then write — so a full disk (the exact moment `headroom` FAILs), a kill or a reboot
        # mid-write leaves it EMPTY BUT FRESH. Read as `ok: True, raw: ""` the record was silently
        # dropped, the one-refresh-old header decided, and both queue checks answered PASS / exit 0
        # with a blank printed where the verdict should be: agent-infra#1931 as health, one shape
        # beyond the failed-read and UNPARSEABLE shapes already closed. The harness's own
        # `queue_state_token` maps an empty body to UNKNOWN; this must agree.
        qs["ok"] = False
        qs["raw"] = None
        qs["error"] = "empty state/queue-state record (torn write)"
    else:
        qs["ok"] = True
        qs["raw"] = qs_raw.strip()[:120]
        m = re.search(r"\b(\d{9,})\b", qs_raw)
        # Same rule, and this one is load-bearing for a verdict: `queue_stale_s` is the defence that
        # stops a frozen pool read from establishing EMPTINESS, and `max(0.0, …)` let a clock running
        # ahead of the canary make a stale record read as 0s old.
        qs["age_s"] = _age_of(now, int(m.group(1))) if m else None
        if qs["age_s"] is None:
            # The harness writes `"$token $(date +%s)"`; a record whose epoch field never got written
            # still has an mtime, which IS when it was recorded. Without this its currency was
            # permanently UNKNOWN and `queue_stale_s` could never fire on it.
            mt = machine.stat_mtime(os.path.join(cfg.o_dir, "state", "queue-state"))
            if mt is not None:
                qs["age_s"] = _age_of(now, mt)
                qs["age_source"] = "file mtime"
    return qs


def _log_repo_of(f):
    """The repo this cell's controller says it manages (from `[req]`/`[authority]` lines), or None."""
    e = newest(((f.get("log_events") or {}).get("repo")) or [])
    return (e or {}).get("repo")


def _is_count(n):
    """A count is an int and a bool is not a count (`isinstance(True, int)` is True)."""
    return isinstance(n, int) and not isinstance(n, bool)


def _is_age(a):
    """An age is a number and a bool is not an age: `True <= 720` reads as ONE SECOND.

    ⛔ THE SAME RULE AS `_is_count`, AND IT WAS APPLIED TO SOME READERS AND NOT OTHERS — a bool
    `age_s` certified a stale lander decision as CURRENT and let a spawn from an earlier cycle vouch
    for the newest batch. Any age compared against a window or a batch clock goes through here.
    """
    return isinstance(a, (int, float)) and not isinstance(a, bool)


def _queue_age(f):
    """The age of THIS pool reading, and where it came from.

    Two independent clocks carry it, and BOTH are read rather than trusting the header alone: the
    token's own `(57m)` suffix (which the refresh appends for exactly this purpose) and the
    `state/queue-state` epoch. The OLDER of the two is the honest age — a fresh token beside a state
    file nobody has rewritten for hours means the writing side is frozen, not that the read is new.
    """
    events = f.get("log_events") or {}
    hdr = newest(events.get("headers"))
    tok_age = parse_queue_token(hdr.get("queue_token") or "").get("token_age_s") if hdr else None
    qs = f.get("queue_state") or {}
    # ⛔ `is True`, like every other `ok` reader in this file: a string "false" is TRUTHY, so a record
    # that FAILED to read supplied its `age_s` as an age attributed to the header ("read 27.8h ago").
    qs_age = qs.get("age_s") if qs.get("ok") is True else None
    # `isinstance(True, int)` is True, so a bool age reads as ONE SECOND here — the sibling of the
    # gate that `_graded_stale`'s state-record branch already refuses.
    ages = [(a, "token") for a in [tok_age] if _is_age(a)]
    ages += [(a, "state/queue-state") for a in [qs_age] if _is_age(a)]
    if not ages:
        return None, None
    age, src = max(ages, key=lambda t: t[0])
    return age, src


def _queue_stale_limit(c):
    """Seconds after which a pool reading is stale. A limit of 0 means ANY age is stale: honoured,
    not treated as unset (`limit or 5400` silently made 'no tolerance' lenient)."""
    limit = getattr(c, "queue_stale_s", None)
    return 5400.0 if limit is None else float(limit)


def _graded_stale(f, c, tok_src):
    """{"age_s", "source", "limit_s"} when the GRADED pool record is not usable as CURRENT, else None.

    ⛔ THE GRADED RECORD'S CURRENCY IS ITS OWN. `_queue_age` reads both clocks and takes the OLDER,
    which is right for the header branch (there the state file IS the older clock, and a token that
    looks fresh beside a state file nobody has rewritten for hours means the writing side is frozen).
    It is wrong for the state-record branch: `authoritative_queue_token` grades `state/queue-state`
    when that record is newer or unaged, and taking the max over both then certified the record with
    the age of the SUPERSEDED header token. Measured: an age-UNKNOWN `EMPTY` record beside a
    `READ(203)(9m)` header graded PASS/READABLE + PASS/IDLE_EMPTY_POOL and exit 0 while printing
    "written age UNKNOWN" in its own evidence — contradicting the rule that an `EMPTY` read carrying
    no age is STATE_FROZEN. The record that was graded answers for itself.
    """
    limit = _queue_stale_limit(c)
    if tok_src == "state/queue-state":
        qs = f.get("queue_state") or {}
        # ⛔ A BOOL IS NOT AN AGE. `age <= limit` reads `True` as ONE SECOND, so a 3-hour-old EMPTY
        # record whose `age_s` was a boolean certified as CURRENT — the #1931 frozen-refresh shape
        # defeated from inside the gate that exists to catch it.
        _raw_age = qs.get("age_s") if qs.get("ok") is True else None
        age = _raw_age if _is_age(_raw_age) else None
        src = ("state/queue-state (no epoch, no readable mtime)" if age is None
               else "state/queue-state")
    else:
        age, src = _queue_age(f)
        src = src or "no age in the token or the state file"
    if age is None:
        # an unaged reading cannot support ANY claim, least of all EMPTINESS: the harness itself
        # emits a bare token when its epoch field is missing or unparsable, and calls such a record
        # "a stale flag waiting to be read as current"
        return {"age_s": None, "source": src, "limit_s": limit}
    if age <= limit:
        return None      # a limit of 0 means "any age is stale": honoured, not treated as unset
    return {"age_s": age, "source": src, "limit_s": limit}


def _queue_frozen_txt(f, stale):
    events = f.get("log_events") or {}
    hdr = newest(events.get("headers"))
    lines = ["pool read age: %s (source: %s, limit %.0fs)"
             % (_age_txt(stale["age_s"]) if stale["age_s"] is not None else "UNKNOWN (no age)",
                stale["source"], stale["limit_s"])]
    if hdr:
        lines.append("cycle header: %s" % hdr.get("raw"))
    qs = f.get("queue_state") or {}
    if qs.get("raw"):
        lines.append("state/queue-state: %s (%s)" % (qs.get("raw"), _age_txt(qs.get("age_s"))))
    return "\n".join(lines)


# `gh pr list --json statusCheckRollup` builds `contexts(first:100)` and drops `pageInfo`, so a
# rollup at the bound may be missing checks entirely. One bound, named once.
GRAPHQL_ROLLUP_PAGE = 100


def rollup_truncated(rollup):
    """True when a rollup read reached the GraphQL page bound (it may be missing checks)."""
    return isinstance(rollup, list) and len(rollup) >= GRAPHQL_ROLLUP_PAGE


def authoritative_queue_token(f, hdr):
    """(token, raw, source) — the NEWER of the header token and `state/queue-state`'s own verdict.

    ⛔ THE HEADER TOKEN IS ALWAYS ONE REFRESH OLD, AND THE STATE RECORD WAS NEVER PARSED. `orch-loop.sh`
    writes the cycle header at the TOP of a cycle (`:832`) and runs `refresh-candidates.sh` LATER in
    the same cycle (`:1607`), so the newest header's `queue=` token is derived from the PREVIOUS
    refresh and `state/queue-state` is always the newer record. Only its epoch was read, so a
    header `EMPTY(3m)` beside a 40s-old `state/queue-state: UNREADABLE` graded
    `PASS/READABLE` + `PASS/IDLE_EMPTY_POOL` and exit 0, with no message — agent-infra#1931
    ("the fleet is BLIND, which is not 'nothing to do'") recorded as health. Measured on this box:
    header `queue=READ(218)` beside `state/queue-state: PARTIAL(P2-moderate)`.

    ⛔ A RECORD THAT WAS READ AND PARSED IS AUTHORITATIVE EVEN WITH NO EPOCH. Requiring an age made
    the fix cover only the shapes that carry one: the harness prints a bare token when its `$at`
    field is missing or unparsable (a record `refresh-candidates.sh` calls "torn or hand-edited"), so
    an UNREADABLE record with no epoch was silently DEMOTED and the one-refresh-old header decided —
    the same PASS/READABLE + PASS/IDLE_EMPTY_POOL + exit 0, reached through the one shape the fix did
    not cover, with the contradicting `UNREADABLE` printed bare in its own evidence. The age question
    belongs to `_graded_stale`, which already answers STATE_FROZEN for an unaged
    EMPTINESS: an unaged record must lose its CLAIM, never its authority.
    """
    hdr_tok = parse_queue_token(hdr.get("queue_token") if hdr else "")
    qs = f.get("queue_state") or {}
    qs_raw = (qs.get("raw") or "").strip()
    qs_tok = parse_queue_token(qs_raw) if (qs_raw and qs.get("ok") is True) else None
    # ⛔ `UNPARSEABLE` IS AUTHORITATIVE TOO — one rule for both sources. `refresh-candidates.sh`'s
    # `queue_state_token` maps a token outside the vocabulary to UNKNOWN, and the harness's own suite
    # writes exactly that (`garbage here`), so excluding it graded the same record two ways: as the
    # header it was FAIL/QUEUE_NEVER_READ, as the state record it was silently dropped and the stale
    # header decided. A RECORD THAT WAS READ IS THE VERDICT; only a FAILED READ is not.
    if qs_tok is not None:
        hdr_age = hdr.get("age_s") if hdr else None
        qs_age = qs.get("age_s")
        # A NEWER record always wins; an UNKNOWN age is not "older" — the record still holds the
        # verdict the fleet wrote, and only its currency is in doubt (`_graded_stale` judges it).
        # ⛔ `_is_age`, so a boolean age is UNKNOWN like an absent one instead of reading as 1s.
        if not _is_age(qs_age) or not _is_age(hdr_age) or qs_age < hdr_age:
            return qs_tok, qs_raw.split()[0] if qs_raw.split() else qs_raw, "state/queue-state"
    return hdr_tok, (hdr.get("queue_token") or "(absent)") if hdr else "(absent)", "cycle header"


def _queue_state_file_txt(f):
    qs = f.get("queue_state") or {}
    if qs.get("ok") is False:
        return "state/queue-state: unreadable (%s)" % (qs.get("error") or "?")
    if qs.get("raw") is None:
        return "state/queue-state: not consulted"
    return "state/queue-state: %s (written %s)" % (qs.get("raw"), _age_txt(qs.get("age_s")))


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Check 3 — WORK WAS DISPATCHED (the outcome that matters most)
# ════════════════════════════════════════════════════════════════════════════════════════════════


def check_work_dispatched(f, c):
    events = f.get("log_events") or {}
    win = c.window_s
    refused_all = [r for r in events.get("dispatch_refused") or []
                   if _is_age(r.get("age_s")) and r["age_s"] <= win]
    refused_txt = ""
    if refused_all:
        reasons = {}
        for r in refused_all:
            k = (r.get("reason") or "(no reason printed)").strip()
            reasons[k] = reasons.get(k, 0) + 1
        top = sorted(reasons.items(), key=lambda kv: -kv[1])
        refused_txt = ("\nalso in the window: %d REFUSED dispatch attempt(s) — %s; most recent: %s"
                       % (len(refused_all),
                          "; ".join("%s x%d" % (w, n) for w, n in top[:3]),
                          refused_all[-1].get("raw")))
    refused = refused_all
    empty = newest_with_age(events.get("dispatch_empty"), win)
    skipped = newest_with_age(events.get("dispatch_skipped"), win)
    hdr = newest_with_age(events.get("headers"), win)
    backlog = hdr.get("backlog") if hdr else None
    # The SAME authoritative token `queue_readable` grades, so the two checks cannot disagree about
    # whether the pool was read as empty (they did: header EMPTY, state UNREADABLE).
    _tok, _unused_raw, _tok_src = authoritative_queue_token(f, hdr)
    # (`_tok`'s pool is NOT read here: the pool/backlog comparison below uses the header's OWN pair,
    # because this check's backlog comes from the header and pairing the two refreshes was the defect.)
    pool_kind = _tok.get("kind")
    last_ok = newest(events.get("dispatch_ok"))

    ev_lines = []
    if hdr:
        ev_lines.append("cycle header: %s" % hdr.get("raw"))
    if refused:
        reasons = {}
        for r in refused:
            k = (r.get("reason") or "(no reason printed)").strip()
            reasons[k] = reasons.get(k, 0) + 1
        top = sorted(reasons.items(), key=lambda kv: -kv[1])
        ev_lines.append("%d refusal(s) in the window, by reason:" % len(refused))
        for why, n in top[:4]:
            ev_lines.append("  x%-4d %s" % (n, why))
        ev_lines.append("  most recent: [%s] %s" % (_age_txt(refused[-1].get("age_s")),
                                                    refused[-1].get("raw")))
    if empty:
        ev_lines.append("backlog-empty line (%s): %s" % (_age_txt(empty.get("age_s")),
                                                         empty.get("raw")))
    if skipped:
        ev_lines.append("last gate skip (%s): %s" % (_age_txt(skipped.get("age_s")),
                                                     skipped.get("raw")))
    ev_lines.append("last successful dispatch line: %s"
                    % (("%s (%s)" % (last_ok.get("raw"), _age_txt(last_ok.get("age_s"))))
                       if last_ok else "NONE in the parsed log tail"))
    ok = newest_with_age(events.get("dispatch_ok"), win)
    unparsed = events.get("unparsed_headers") or 0
    if unparsed:
        # The same datum `queue_readable` reads: "no cycle in the window" is a claim about the LOG,
        # and N headers the parser could not read make it false. One rule, both checks.
        ev_lines.append("%d header(s) present but UNPARSEABLE — the log format moved" % unparsed)
    evidence = "\n".join(ev_lines)

    # ⛔ THE BATCH LINE IS AN INTENT. `[dispatch] load=… -> N` is echoed BEFORE `dispatch-merge.sh`
    # runs, and its spawn can fail silently (no else on the `tmux new-session` branch) or with its own
    # `#N: worktree add failed` / `#N: chain-N could NOT be started` lines. Grading the intent as the
    # outcome is a PASS on "everything is up and nothing ships" — measured: 110 of 110 real batch
    # lines are followed by `#N: lane-N (implement+PR)`, so the proof is in the tail and unpriced.
    if ok is not None:
        # ⛔ THE SPAWN MUST BELONG TO THE BATCH BEING GRADED. `newest_with_age` over ALL lane lines
        # meant an OLDER cycle's spawn vouched for the newest batch: measured input — previous batch
        # (540s) spawned 4400/4401, newest batch (60s) spawned nothing → PASS/DISPATCHED and exit 0,
        # which is precisely the silently-failed spawn (`dispatch-merge.sh` has no `else` on the
        # `tmux new-session` branch) this check exists to catch. A spawn cannot precede its intent,
        # so it must be for one of this batch's issues and no older than the batch line.
        batch_issues = [str(i) for i in (ok.get("issues") or [])]
        ok_age = ok.get("age_s")

        def _is_this_batch(e):
            if e is None:
                return False
            # ⛔ UNCONDITIONAL. `batch_issues and …` let an empty issue list switch the guard OFF,
            # so a spawn for an issue in NO batch vouched for a batch that named none — measured:
            # "0 issue(s) dispatched" + PASS/DISPATCHED + exit 0. A malformed batch line cannot
            # spawn anything, so nothing may vouch for it.
            if str(e.get("issue")) not in batch_issues:
                return False
            # ⛔ `_is_age`, NOT `is None`. `age_s: true` is one second, so a spawn from an earlier
            # cycle was credited to the NEWEST batch — `PASS/DISPATCHED`, "lane spawn (1s ago)",
            # exit 0 — the exact measured failure this guard was written for.
            if not _is_age(e.get("age_s")) or not _is_age(ok_age):
                return False
            # +2s: both take their age from the same cycle header, but a per-line timestamp (or a
            # second-granularity difference) must not turn a real spawn into an abstention.
            return e["age_s"] <= ok_age + 2.0

        all_started = events.get("lane_started") or []
        all_failed = events.get("lane_failed") or []
        # ⛔ A START REFUTED BY ITS OWN FAILURE LINE IS NOT A LIVE LANE. `dispatch-merge.sh:93` prints
        # `#N: chain-N could NOT be started — stopping lane-N (its PR would never be merged)` AFTER
        # echoing the lane line, and then kills it: measured with the emitter's literal lines for a
        # 3-issue batch (2 worktree failures + 1 started-then-killed) the check read
        # PASS/DISPATCHED, printing "3 issue(s) dispatched" off the batch INTENT count — the very
        # datum the comment above says must not be graded.
        # ⛔ A FAILURE REFUTES ONLY A START IT IS NOT OLDER THAN. `failed_issues` was an ORDER-BLIND
        # set of issue numbers, so ANY `chain-N could NOT be started` inside the batch window
        # disqualified every start for that issue however much newer: a normal retry (failure 240s
        # ago, lane started 60s ago) produced FAIL/NO_LANE_STARTED — "EVERY spawn failed" — while
        # `_activity`, reading the same facts, confirmed the lane 60s ago. One world graded two ways,
        # and the FAIL is the one that pages. `_activity`'s own scoping helper is the rule; use it.
        batch_fails = [e for e in all_failed if _is_this_batch(e)]

        def _refuted(start):
            return any(str(fe.get("issue")) == str(start.get("issue"))
                       and _refutes_scoped(fe, start) for fe in batch_fails)

        live = [e for e in all_started if _is_this_batch(e) and not _refuted(e)]
        started = newest_with_age(live, win)
        spawn_fail = newest_with_age([e for e in all_failed if _is_this_batch(e)], win)
        foreign = newest([e for e in all_started if not _is_this_batch(e)])
        spawn_txt = ""
        if started is None and foreign is not None:
            # Named, so a truncated tail and a silent spawn failure stay distinguishable in one read.
            spawn_txt = ("\nlane spawn for a DIFFERENT batch (%s): %s — it does not vouch for this "
                         "one" % (_age_txt(foreign.get("age_s")), foreign.get("raw")))
        if started is not None:
            spawn_txt = "\nlane spawn (%s): #%s lane-%s (implement+PR)" % (
                _age_txt(started.get("age_s")), started.get("issue"), started.get("lane"))
        if spawn_fail is not None:
            spawn_txt += "\nlane spawn FAILED (%s): %s" % (
                _age_txt(spawn_fail.get("age_s")), spawn_fail.get("raw"))
        if started is None:
            if spawn_fail is not None:
                return V("work_dispatched", FAIL, "NO_LANE_STARTED",
                         evidence + spawn_txt,
                         "a dispatch batch was issued and EVERY spawn failed: the `[dispatch] -> N` "
                         "line is written before the spawner runs, so it is an intention, not an "
                         "outcome. Nothing was started, so no work is going out.")
            return V("work_dispatched", INCONCLUSIVE, "DISPATCH_UNCONFIRMED",
                     evidence + spawn_txt,
                     "a dispatch batch was issued, but no lane-spawn outcome (`#N: lane-N "
                     "(implement+PR)`) appears in the window — so 'work was dispatched' rests on the "
                     "intent line alone. Not green.")
        # PASS is PASS by the outcome, but the refusals and the spawns are EVIDENCE and a pass that
        # hides them is the green-while-broken failure this whole file exists to end. Always printed.
        return V("work_dispatched", PASS, "DISPATCHED",
                 "dispatch line (%s): %s (batch INTENT: %d issue(s))\n%d lane(s) STARTED inside the "
                 "%.0fs window%s%s"
                 % (_age_txt(ok.get("age_s")), ok.get("raw"), ok.get("issue_count") or 0,
                    len(live), win, refused_txt, spawn_txt))

    # POSITIVE evidence that work existed and none of it went out → FAIL. This is the check's whole
    # point; it is the branch that catches "everything is up and nothing ships".
    if refused:
        # ⛔ THIS PREDICATE READS THE LOG, NOT THE CONTROLLER CENSUS AND NOT THE QUEUE RECORD. It
        # said "The controller is cycling, the queue is readable" unconditionally — so a run whose
        # controller was ABSENT (`FAIL/CONTROLLER_ABSENT`) and whose queue record was UNREADABLE
        # printed, inside the very message `compose_message` delivers, two facts it never took, one
        # of them contradicting the `queue=UNREADABLE` in its own evidence block.
        return V("work_dispatched", FAIL, "NOT_DISPATCHED", evidence,
                 "%d dispatch attempt(s) were REFUSED in the window and NO lane was started, so no "
                 "work is going out. (This check reads the dispatch log; whether the controller is "
                 "alive is `controller_cycling`'s verdict, and whether the pool is readable is "
                 "`queue_readable`'s.)" % len(refused))
    # No dispatch, no refusals, nothing in the backlog: is that IDLE or BLIND?
    # ⛔ THE SAME AUTHORITATIVE TOKEN `queue_readable` GRADES. Reading the header's token here while
    # `queue_readable` read the newer state record let a BLIND refresh be called IDLE: header
    # `EMPTY` + newer `state/queue-state: UNREADABLE` → PASS/IDLE_EMPTY_POOL (agent-infra#1931 as
    # health). One source, both checks.
    if hdr is None:
        return V("work_dispatched", INCONCLUSIVE, "NO_CYCLE_IN_WINDOW", evidence,
                 "no cycle ran in the window, so whether work existed is unknown. Not green.")
    # One completeness rule, both checks: a header with no `backlog=` field is INCOMPLETE, and
    # `queue_readable` already refuses to grade it. Accepting the absence as zero here let
    # `work_dispatched` — "the one that matters most" — assert that a fleet's non-dispatch was
    # CORRECT on evidence the module had declared incomplete.
    stale = _graded_stale(f, c, _tok_src)
    if stale is not None:
        # "Nothing to dispatch" is the CORRECT outcome only on a CURRENT read, and "work existed and
        # did not move" is a claim about NOW. A frozen read establishes neither — so ANY stale read
        # abstains here, including a legible non-empty one. The guard used to exempt a stale NON-EMPTY
        # read with a non-empty backlog, which let `work_dispatched` grade FAIL/NO_DISPATCH ("the
        # refresh reported %d candidate(s) and no dispatch line was written") off a reading hours old,
        # while `queue_readable` abstained on the very same record — one facts dict, two answers, and
        # the FAIL was the one that would have paged someone.
        return V("work_dispatched", INCONCLUSIVE, "STATE_FROZEN", _queue_frozen_txt(f, stale),
                 ("the pool was read %s (limit %.0fs), so neither 'there was nothing to "
                  "dispatch' nor 'work existed and did not move' is established. Not green." % (
                      _age_txt(stale["age_s"]), stale["limit_s"]))
                 if stale["age_s"] is not None else
                 ("the pool reading carries NO AGE (no epoch in the token, none in "
                  "state/queue-state), so 'there was nothing to dispatch' cannot be told from a "
                  "record frozen hours ago. Not green."))
    # ⛔ A SUPERSEDED BACKLOG CANNOT SUPPORT "work existed and did not move". The header's
    # `backlog=` and `queue=` are ONE refresh old (`orch-loop.sh` writes the header at the top of the
    # cycle; the refresh runs later), so when the newer `state/queue-state` reads the pool EMPTY, the
    # header's 47 remaining candidates are already gone. Grading them anyway produced, for ONE facts
    # dict, `queue_readable PASS/READABLE ("graded from: state/queue-state, it is NEWER")` beside
    # `work_dispatched FAIL/NO_DISPATCH ("the refresh reported 47 candidate(s) … work existed and did
    # not move")` — exit 1 and a message to the controller, about a backlog a 40-second-old record had
    # already superseded. `_activity` and `queue_readable` both honour this; this was the third check
    # in the file still reading the superseded field.
    superseded_backlog = (pool_kind == "EMPTY" and _tok_src == "state/queue-state" and stale is None)
    # ⛔ THESE TWO FAIL ARMS REST ON THE QUEUE RECORD, so they sit BELOW the staleness abstention.
    # Above it they were reached first and graded FAIL/NO_DISPATCH ("the refresh reported 47
    # candidate(s) and no dispatch line was written… Work existed and did not move") off a six-hour-old
    # reading — the exact claim the abstention exists to withhold, and a FAIL that pages someone while
    # `queue_readable`, on the same record, abstains. An abstention placed after the arm it must
    # suppress is dead code (the same structural bug as `check_pr_merged`'s in cycle 23).
    # ⛔ `isinstance(True, int)` IS TRUE. A `backlog: true` reached both arms below and FAILed with
    # "the refresh reported 1 candidate(s)" — a count manufactured from a boolean, on the check whose
    # FAIL delivers a message. `_activity` and `queue_readable` already guard the same field.
    if _is_count(backlog) and backlog > 0 and skipped is not None \
            and not superseded_backlog:
        return V("work_dispatched", FAIL, "NO_DISPATCH_GATED", evidence,
                 "the refresh reported %d candidate(s) and the dispatch gate skipped every cycle "
                 "in the window (reason on the [dispatch] skipped line above). The outcome is "
                 "absent — the evidence names WHY, which distinguishes a gated fleet from a "
                 "silently dead one." % backlog)
    if _is_count(backlog) and backlog > 0 and not superseded_backlog:
        return V("work_dispatched", FAIL, "NO_DISPATCH", evidence,
                 "the refresh reported %d candidate(s) and no dispatch line was written in the "
                 "window. Work existed and did not move." % backlog)
    if pool_kind == "EMPTY" and backlog is None:
        return V("work_dispatched", INCONCLUSIVE, "HEADER_INCOMPLETE",
                 "queue=EMPTY but the header carries no `backlog=` field: %s" % hdr,
                 "an incomplete header cannot establish that the pool was genuinely empty, so "
                 "'nothing to dispatch' is not established. Not green.")
    # ⛔ `False == 0` IS TRUE. Un-guarded, this arm read a boolean `backlog` as a measured zero and
    # returned PASS/IDLE_EMPTY_POOL — "the pool was read as genuinely EMPTY", exit 0, no message —
    # from a field that was never a count. The FAIL arms above were healed first; this one, the GREEN
    # one, is the one a bool can silence.
    if pool_kind == "EMPTY" and ((_is_count(backlog) and backlog == 0) or superseded_backlog) \
            and (f.get("queue_state") or {}).get("ok") is True:
        return V("work_dispatched", PASS, "IDLE_EMPTY_POOL", evidence,
                 "nothing was dispatched because the pool was read as genuinely EMPTY — the one "
                 "shape where 'no dispatch' is the correct outcome.")
    # ⛔ THE PAIR COMES FROM ONE RECORD. Comparing the GRADED token's pool (possibly the NEWER
    # state/queue-state) against the header's `backlog=` compared two refreshes and reported the
    # difference as a defect "upstream (queue_readable owns it)" — a defect `queue_readable`'s own
    # `EMPTY_WITH_LARGE_POOL` arm can never report, because it deliberately pairs the pool with ITS
    # OWN header. This function reads the header's own pair, and says only what that pair shows.
    _pair = parse_queue_token(hdr.get("queue_token") or "") if hdr else {}
    if _is_count(_pair.get("pool")) and _pair.get("pool") >= c.pool_threshold \
            and _is_count(backlog) and backlog == 0 and not superseded_backlog:
        return V("work_dispatched", INCONCLUSIVE, "NO_CANDIDATES",
                 evidence + "\nheader pair: pool=%d (above threshold %d) beside backlog=0"
                 % (_pair.get("pool"), c.pool_threshold),
                 "the header's OWN pair shows %d candidates in the pool beside an empty dispatch "
                 "backlog, and nothing was dispatched: whether that is a refresh that lost its "
                 "backlog or a backlog that was genuinely empty one refresh ago cannot be told from "
                 "here, so 'no work dispatched' is not graded as correct OR as a failure. Not green."
                 % _pair.get("pool"))
    return V("work_dispatched", INCONCLUSIVE, "NO_WORK_EVIDENCE", evidence,
             "no dispatch line and no positive evidence that dispatchable work existed. Not green.")


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Checks 4 & 5 — PRs created / merged
# ════════════════════════════════════════════════════════════════════════════════════════════════


def _refutes_scoped(fail, start):
    """Does `fail` refute THIS start? Only a failure for the same issue, no OLDER than the start.

    ⛔ ONE RULE, TWO READERS. `_activity` had this scoping inline and `work_dispatched` substituted a
    bare SET of issue numbers: any failure for an issue refuted every later start of it forever, so a
    normal retry (failure 240s ago, start 60s ago) read "EVERY spawn failed" while `_activity`
    confirmed the lane. An un-ageable start cannot outrank a failure (return True) — the conservative
    direction, because the start is then not evidence either.
    """
    if str(fail.get("issue")) != str(start.get("issue")):
        return False
    fa = fail.get("age_s")
    if not _is_age(fa):
        return False
    sa = start.get("age_s")
    if not _is_age(sa):
        return True
    return fa <= sa + 2.0


def _activity(f, window_s=None, cfg=None):
    """Did the fleet have work in hand? Used to decide whether 'no PR' is a FAILURE or an IDLE.

    ⛔ THE HEADER MUST BE INSIDE THE WINDOW. Every other reader windows it (`newest_with_age(...)`);
    this one took `newest(...)` with no freshness bound, so a THREE-DAY-OLD `backlog=47 pool=223`
    turned an idle fleet into `FAIL/NO_PR_CREATED` + `FAIL/NO_PR_MERGED` ("the fleet HAD WORK IN
    HAND", asserting no PR was opened) while `queue_readable` and `work_dispatched` abstained on the
    very same facts — one world graded two ways, and the FAIL carrying no age in its evidence.
    """
    if cfg is not None and window_s is None:
        window_s = cfg.window_s
    events = f.get("log_events") or {}
    hdr = newest_with_age(events.get("headers"), window_s) if window_s is not None \
        else newest(events.get("headers"))
    # ⛔ THE QUEUE RECORD IS NOT THE ONLY EVIDENCE OF WORK IN HAND, AND SAYING "NOTHING IN HAND" WHEN
    # THE RUN ITSELF PROVES OTHERWISE IS A FALSE STATEMENT EVEN AT EXIT 2. Measured: `work_dispatched`
    # PASS/DISPATCHED from a fresh `[dispatch] … -> 4601` + `#4601: lane-N` sat three lines above
    # `pr_created`'s "the fleet had nothing in hand, so a PR was not expected". Open PRs and a fresh
    # dispatch are the same positive evidence `pr_merged`'s `open_n > 0` arm already trusts.
    #
    # ⛔ AND THESE TWO ARMS ARE ASKED BEFORE THE HEADER IS, because they need no header at all. Ask
    # the absent-header abstention first and they become unreachable exactly when the controller is
    # wedged: a measured field (`open_pr_count`) would be thrown away in favour of "not established"
    # on the one shape where the FAIL matters most. An abstention may only speak about the datum it
    # could not read.
    gh_open = (f.get("github") or {}).get("open_pr_count")
    pr_win = cfg.pr_window_s if cfg is not None else 10800.0
    # ⛔ `dispatch_ok` IS THE BATCH INTENT LINE, NOT A LANDED DISPATCH — `work_dispatched` refuses to
    # grade it as one, and the doc calls it "an INTENT, not the dispatch". Reading it here produced
    # "a dispatch landed 3m ago" in the evidence of a FAIL, three lines under `work_dispatched`'s
    # FAIL/NO_LANE_STARTED ("lane spawn FAILED") for the same batch. A confirmed spawn is preferred,
    # and when only the intent exists the line says so.
    # ⛔ A SPAWN ITS OWN FAILURE LINE REFUTES IS NOT A STARTED LANE. `work_dispatched` drops those
    # (`#4601: chain-1 could NOT be started` → NO_LANE_STARTED) before it counts a start; reading the
    # raw bucket here published "a lane started 3m ago" in the evidence of a FAIL, directly under the
    # check saying the spawn failed. A refuted start leaves the INTENT as the evidence, which is what
    # it always was.
    def _refutes(fail, start):
        """Does `fail` refute THIS start? Only a failure for the same issue, no OLDER than the start
        line, can speak about it — `work_dispatched` scopes the same judgement to the batch and to
        the batch's age. An unscoped set of issue numbers refuted every LATER start of that issue
        forever, so a normal retry (failure 2h ago, start 60s ago) read as "no lane spawn was
        confirmed" while `work_dispatched` PASSed on the same facts."""
        return _refutes_scoped(fail, start)    # the failure came at or after the start line
    _fails = events.get("lane_failed") or []
    lane_ok = newest_with_age([e for e in (events.get("lane_started") or [])
                               if not any(_refutes(f, e) for f in _fails)], pr_win)
    intent = newest_with_age(events.get("dispatch_ok") or [], pr_win)
    if _is_count(gh_open) and gh_open > 0:
        return True, "%d open PR(s) — work in hand, independent of the queue record" % gh_open
    if lane_ok:
        return True, "a lane started %s (the queue record is not the only evidence)" % (
            _age_txt(lane_ok.get("age_s")))
    if intent:
        return True, ("a dispatch was ATTEMPTED %s (the intent line — work existed even though no "
                      "lane spawn was confirmed)" % _age_txt(intent.get("age_s")))
    # ⛔ AN ABSENT HEADER IS NOT AN EMPTY BACKLOG. `False` here means "the fleet had nothing in hand",
    # so a wedged controller (which writes no header) was graded as a measured idle — the opposite of
    # what a missing header shows. `work_dispatched` and `queue_readable` abstain on this shape.
    if not hdr:
        return None, ("no cycle header inside the window, so how much work the fleet had in hand "
                      "is not established")
    backlog = hdr.get("backlog")
    # ⛔ THE SAME AUTHORITATIVE TOKEN the queue checks grade. Reading the one-refresh-old header here
    # made four checks disagree about one world: measured, `queue_readable` FAILed
    # EMPTY_WITH_LARGE_POOL while `pr_created` answered IDLE_NO_WORK ("the fleet had nothing in
    # hand") off the same facts. The pool number and its SOURCE go into the evidence.
    _tok, _raw, _src = authoritative_queue_token(f, hdr)
    pool = _tok.get("pool")
    kind = _tok.get("kind")
    age_txt = _age_txt(hdr.get("age_s"))
    # ⛔ `backlog=` IS WRITTEN BY ONE CYCLE HEADER (from `candidates.txt`, produced by the PREVIOUS
    # refresh — `orch-loop.sh` writes the header at the top and refreshes later), so it cannot be
    # attributed to a NEWER `state/queue-state` record. Measured: header `backlog=47` beside a 20s-old
    # `state/queue-state: EMPTY` produced `backlog=47 pool=None (source: state/queue-state)` and two
    # FAILs ("the fleet HAD WORK IN HAND") about a refresh that had already been superseded. The
    # graded record's own verdict wins: a current EMPTY says there is nothing to dispatch.
    backlog_src = "cycle header"
    # ⛔ AN UNAGED RECORD LOSES ITS CLAIM, NEVER ITS AUTHORITY. `_graded_stale` is what decides
    # currency; without this guard an `EMPTY` with no epoch re-granted "the fleet had nothing in hand"
    # while `queue_readable` and `work_dispatched` both said STATE_FROZEN about the same record.
    if (_src == "state/queue-state" and kind == "EMPTY" and _graded_stale(f, cfg, _src) is None
            and _is_count(backlog)):
        # ⛔ `HEADER_INCOMPLETE` APPLIES HERE TOO. Both siblings refuse to grade an incomplete header
        # (`check_queue_readable` and `check_work_dispatched`: "an incomplete header cannot establish
        # that the pool was genuinely empty"), and this shortcut stands in for exactly that judgement —
        # so without the guard a header with NO `backlog=` field was blessed as a measured idle and
        # the PR checks DELIVERED "the fleet had nothing in hand", the sentence this whole guard
        # exists to prevent. `backlog` is also interpolated below: `backlog=None` would be a claim
        # about a field that was never read.
        return False, ("the graded record is state/queue-state: EMPTY (%s) — it supersedes the "
                       "%s's backlog=%s" % (age_txt, backlog_src, backlog))
    # ⛔ AND THE SAME GUARD RUNS IN THE OTHER DIRECTION. Currency was checked only where it would
    # make the fleet IDLE; the direction that makes it BUSY was unguarded, so a frozen `backlog=47`
    # (written from the PREVIOUS refresh's candidates.txt) certified "the fleet had work in hand" and
    # turned `pr_created`/`pr_merged` into FAIL/NO_PR_CREATED + FAIL/NO_PR_MERGED + two pages —
    # while `queue_readable` said READABLE_STALE and `work_dispatched` said STATE_FROZEN about the
    # same record in the same run. One world, graded two ways, and the FAIL is the one that pages.
    stale_busy = _graded_stale(f, cfg if cfg is not None else cfg_from_dict({}), _src)
    if stale_busy is not None:
        return None, ("the graded pool record (%s: %s) was read %s (limit %ss, %s), which is "
                      "not CURRENT, so 'work was in hand' is not established (and neither is "
                      "'the fleet was idle')"
                      % (_src, kind, _age_txt(stale_busy.get("age_s")),
                         stale_busy.get("limit_s"), stale_busy.get("source")))
    busy = bool((_is_count(backlog) and backlog > 0) or (_is_count(pool) and pool > 0))
    if busy:
        return True, "backlog=%s (source: %s, %s) pool=%s (source: %s)" % (
            backlog, backlog_src, age_txt, pool, _src)
    # ⛔ "NOTHING IN HAND" IS A CLAIM, AND AN UNREAD POOL CANNOT SUPPORT IT. Every non-numeric kind
    # fell through to `busy=False`, so a box whose refresh answered `UNREADABLE` — the #1931 shape
    # this file fixes everywhere else — was reported as benign idleness by `pr_created` while
    # `queue_readable` FAILed QUEUE_UNREADABLE in the same run. `work_dispatched` has a
    # `HEADER_INCOMPLETE` guard for exactly this; `_activity` had none.
    # ⛔ `PARTIAL` IS NOT IN THE ALLOW-LIST. `parse_queue_token` sets `pool` only for `READ(...)`; a
    # `PARTIAL(...)` token carries `partial` and leaves `pool` None, so admitting it let a shape whose
    # pool SIZE was never read fall through to `False` ("the fleet had nothing in hand") while
    # `queue_readable` FAILed QUEUE_PARTIAL — "only some priority tiers were read, so the pool is a
    # SUBSET" — on the same record.
    if (kind not in ("EMPTY", "READ")
            or not _is_count(backlog)
            or (kind == "READ" and not _is_count(pool))):
        # ⛔ BOTH HALVES OF THE PAIR ARE REQUIRED. A header with NO `backlog=` field reaches here
        # whenever the EMPTY-supersede shortcut above declined (an incomplete header is not a measured
        # idle), and an int `backlog=0` beside an `EMPTY` is the only shape that supports "nothing in
        # hand" — the same `HEADER_INCOMPLETE` judgement its two sibling checks make.
        return None, ("the pool reading is %s (source: %s, %s) with backlog=%s, so 'the fleet had "
                      "nothing in hand' is not established"
                      % (_tok.get("raw") or "(absent)", _src, age_txt, backlog))
    return False, "backlog=%s (source: %s, %s) pool=%s (source: %s)" % (
        backlog, backlog_src, age_txt, pool, _src)


def _gh_surface_txt(gh):
    src = gh.get("source")
    note = gh.get("fallback_reason")
    # ⛔ AN ABSENT `source` IS A MISSING DISCLOSURE, NOT A FAILED READ. `source` is optional in a
    # github payload, so `--static`/`--facts` printed the assertion "gh unreadable" 87 times inside
    # GREEN blocks — a claim contradicted by the verdict on the line above it. Say what is true: the
    # surface did not disclose itself.
    txt = ("surface: %s%s" % (src, (" (%s)" % note) if note else "")) if src \
        else "surface: not disclosed by this payload"
    # ⛔ THE DIAGNOSTIC WAS IN HAND AND DISCARDED. `_collect_rest` records WHY each PR went unprobed
    # (`detail_errors`: a 403 on `pulls/<n>`, a truncated check-runs page, an unreadable commit), and
    # nothing read the field — so a report could say "UNPROBED: [7, 9]" while the reason sat in the
    # facts. "Beyond rest_probe_max", "the detail call 403'd" and "this page was truncated" are
    # different failures with different fixes.
    errs = gh.get("detail_errors") or []
    if errs:
        txt += "\nprobe failures (up to 5): %s" % "; ".join(str(e) for e in errs[:5])
    # ⛔ WHICH READ PRODUCED THE MERGE COUNT IS PART OF THE EVIDENCE. The merge count comes from a
    # separate, merge-ordered read; when that read FAILED the count falls back to a creation-ordered
    # page and the bound is admitted. `merged_surface`/`fallback_note` were written by the collector
    # and read by NOTHING, so a report could not tell a window-bounded count from a page-bounded one.
    merge = gh.get("merged_surface") or gh.get("fallback_note")
    return "%s\nmerged count from: %s" % (txt, merge) if merge else txt


def check_pr_created(f, c):
    gh = f.get("github") or {}
    win = c.pr_window_s
    # ⛔ ALLOW-LIST polarity (same rule as `rollup_is_green`): `is False` reads a MISSING read as a
    # good one, so a facts dict with no github surface made `landers` PASS on "open PRs: 0".
    if gh.get("ok") is not True:
        return V("pr_created", INCONCLUSIVE, "GH_UNREADABLE",
                 "gh: %s" % (gh.get("error") or "call failed"),
                 "the PR population could not be read, so 'no PR was created' is not established. "
                 "Not green.")
    n = gh.get("prs_created_in_window")
    # ⛔ AN `ok` SURFACE WITH NO COUNT IS NOT A MEASURED ZERO. `isinstance(n, int) and n > 0` sends
    # `None` into the FAIL branch, so a payload that answered but carries no
    # `prs_created_in_window` produced `FAIL/NO_PR_CREATED` — asserting the fleet "opened no PR in
    # 3.0h" off a field that was never read, and printing `PRs created in the last 3h: None` beside
    # it. Same rule as headroom's `ok`-with-no-number guard: a FAIL on this check means one was
    # MEASURED, or it means nothing.
    # ⛔ `isinstance(True, int)` IS TRUE: a payload carrying `prs_created_in_window: true` graded
    # PASS/ CREATED with "PRs created in the last 3h: True". `_check_rank` already guards its `id`
    # the same way; a count is an int and a bool is not a count.
    if not _is_count(n):
        return V("pr_created", INCONCLUSIVE, "GH_COUNT_UNREAD",
                 "the gh surface answered but carries no prs_created_in_window (got %r)\n%s"
                 % (n, _gh_surface_txt(gh)),
                 "the created count was not read, so 'no PR was created' is not established. "
                 "Not green.")
    # ⛔ The labels and the values were CROSSED: `open=` printed the merged count and `merged=` the
    # open count, so the evidence of a PASS contradicted `pr_merged`'s own block two checks later
    # (measured live: "PRs created in the last 3h: 25 / (open=13 merged=24)" for 24 open, 13 merged).
    ev = ("PRs created in the last %.2gh: %s\n(open=%s merged=%s in the same window)\n"
          "last created: %s\n%s"
          % (win / 3600.0, n, gh.get("open_pr_count"), gh.get("prs_merged_in_window"),
             gh.get("last_created") or "none in the query window", _gh_surface_txt(gh)))
    if _is_count(n) and n > 0:
        return V("pr_created", PASS, "CREATED", ev)
    busy, why = _activity(f, cfg=c)
    if busy is None:
        return V("pr_created", INCONCLUSIVE, "ACTIVITY_UNKNOWN", ev + "\nfleet activity: %s" % why,
                 "whether the fleet had work in hand could not be read, so 'no PR was created' is "
                 "neither a failure nor an idle. Not green.")
    if busy:
        return V("pr_created", FAIL, "NO_PR_CREATED", ev + "\nfleet activity: %s" % why,
                 "the fleet had work in hand and opened no PR in %.1fh. A fleet that dispatches "
                 "and never opens PRs is not doing the work." % (win / 3600.0))
    return V("pr_created", INCONCLUSIVE, "IDLE_NO_WORK",
             ev + "\nfleet activity: %s" % why,
             "no PR was created and the fleet had nothing in hand, so a PR was not expected. "
             "Not green — and not a failure.")


def check_pr_merged(f, c):
    gh = f.get("github") or {}
    win = c.pr_window_s
    if gh.get("ok") is not True:
        return V("pr_merged", INCONCLUSIVE, "GH_UNREADABLE",
                 "gh: %s" % (gh.get("error") or "call failed"),
                 "the merge population could not be read. Not green.")
    n = gh.get("prs_merged_in_window")
    open_n = gh.get("open_pr_count")
    # ⛔ AN `ok` SURFACE WITH NO COUNT IS NOT A MEASURED ZERO — see `check_pr_created`. Without this,
    # a payload with no `prs_merged_in_window` reached the `open_n > 0` branch and reported
    # "N PR(s) are open and nothing merged in 3.0h" off a count it never read.
    if not _is_count(n):
        return V("pr_merged", INCONCLUSIVE, "GH_COUNT_UNREAD",
                 "the gh surface answered but carries no prs_merged_in_window (got %r)\n%s"
                 % (n, _gh_surface_txt(gh)),
                 "the merge count was not read, so 'nothing merged' is not established. Not green.")
    ev = ("PRs MERGED in the last %.2gh: %s\nopen PRs now: %s\nlast merged: %s\n%s"
          % (win / 3600.0, n, open_n, gh.get("last_merged") or "none in the query window",
             _gh_surface_txt(gh)))
    if _is_count(n) and n > 0:
        return V("pr_merged", PASS, "MERGED", ev)
    busy, why = _activity(f, cfg=c)
    # ⛔ THE COVERAGE BIT IS A BIT, NOT A HINT. `merged_page_full is None` fell back to
    # `n >= 100` — the count INSIDE the window, while truncation is a property of the ROWS the page
    # returned, and a truncated page normally has `n == 0` (which is why the collector coerces an
    # unprovable coverage to True). So the fallback could essentially never fire, and an ABSENT or
    # non-bool bit was read as a definite "the page is complete": a `FAIL/NO_PR_MERGED` claiming
    # "nothing merged" over a merge population whose coverage was never established — the polarity
    # this file applies to every other bit. Only `is False` establishes coverage; anything else
    # abstains, and the detail says which it was.
    mpf = gh.get("merged_page_full")
    if mpf is not False and not (_is_count(n) and n > 0):
        # A FULL, creation-ordered page cannot tell "nothing merged" from "merged PRs created before
        # the page cut". Abstaining is the honest answer; a FAIL here would be a false alarm, and a
        # PASS impossible.
        return V("pr_merged", INCONCLUSIVE, "MERGED_SURFACE_TRUNCATED",
                 ev + ("\nthe merged list hit its 100-row page bound (it is creation-ordered), so a "
                       "merge older than the page cut cannot be seen" if mpf is True else
                       "\nthe page's coverage of the window was NOT REPORTED (merged_page_full=%r), "
                       "so a merge outside the page cannot be ruled out" % (mpf,)),
                 "the merge population's coverage is unknown, so 'nothing merged in the window' is "
                 "not established. Not green.")
    if busy is None:
        # ⛔ HOISTED ABOVE THE `open_n > 0` ARM. The two PR checks answer one question, so they must
        # answer it the same way: `pr_created` abstained ACTIVITY_UNKNOWN on the #1931 blind-pool
        # shape while `pr_merged` FAILed NO_PR_MERGED off the very same facts, with its own evidence
        # line saying "the pool reading is UNREADABLE … so 'the fleet had nothing in hand' is not
        # established" — a FAIL block that disclaims the reading it used, and the block `main`
        # turns into a delivered message. The `open_n > 0` arm keeps its FAIL when activity IS known.
        return V("pr_merged", INCONCLUSIVE, "ACTIVITY_UNKNOWN", ev + "\nfleet activity: %s" % why,
                 "whether the fleet had work in hand could not be read, so 'nothing merged' is "
                 "neither a failure nor an idle. Not green.")
    if _is_count(open_n) and open_n > 0:
        return V("pr_merged", FAIL, "NO_PR_MERGED", ev + "\nfleet activity: %s" % why,
                 "%d PR(s) are open and nothing merged in %.1fh. Every component can be 'up' while "
                 "the fleet ships nothing — that is this check's whole reason to exist."
                 % (open_n, win / 3600.0))
    if busy:
        return V("pr_merged", FAIL, "NO_PR_MERGED", ev + "\nfleet activity: %s" % why,
                 "the fleet had work in hand and merged nothing in %.1fh." % (win / 3600.0))
    return V("pr_merged", INCONCLUSIVE, "IDLE_NO_WORK", ev + "\nfleet activity: %s" % why,
             "nothing merged and nothing was in hand, so a merge was not expected. Not green.")


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Check 6 — the pane daemon, and whether anything protects it
# ════════════════════════════════════════════════════════════════════════════════════════════════


def check_pane_daemon(f, c):
    pane = f.get("pane") or {}
    cmd = pane.get("cmd") or "cmux-tui"
    # ⛔ `pids or []` GRADED AN UNREAD POPULATION AS ZERO DAEMONS. `ok: True` with the list absent
    # reached `FAIL/DAEMON_ABSENT` — "processes matching cmux-tui: 0", a MEASURED failure reported
    # from a value that was never read, and the exact shape `check_landers` rejects one check over
    # (`if not isinstance(prs, list)`). A census that answered without a list answered nothing.
    if pane.get("ok") is True and not isinstance(pane.get("pids"), list):
        return V("pane_daemon", INCONCLUSIVE, "PROCESS_TABLE_UNREADABLE",
                 "the pane census answered without a `pids` list (keys: %s)\n%s"
                 % (sorted(pane.keys()), _pane_protection_txt(pane)),
                 "the daemon population was not read, so 'no %s is running' is not established. "
                 "Not green." % cmd)
    pids = pane.get("pids") if isinstance(pane.get("pids"), list) else []
    if pane.get("ok") is not True:
        return V("pane_daemon", INCONCLUSIVE, "PROCESS_TABLE_UNREADABLE",
                 "process table read failed: %s" % (pane.get("error") or "?"),
                 "whether the pane daemon is alive could not be established. Not green.")
    # ⛔ THE PANE CENSUS IS SCOPED TOO. `pick_pane_daemon_pids` rejects an interpreter invocation
    # with a flag before the binary (`node --enable-source-maps /usr/local/bin/cmux-tui`), so a live
    # daemon can be a `near_miss`; the FAIL then printed "REJECTED (mentioned the name, is not the
    # daemon): …" in its own evidence while asserting "processes matching cmux-tui: 0". Every other
    # unread in this check abstains; a non-empty near-miss list must too.
    pane_near = _names_our_program(pane.get("near_misses") or [],
                                  names=(os.path.basename(cmd),))
    if not pids and pane_near:
        return V("pane_daemon", INCONCLUSIVE, "DAEMON_CENSUS_NEAR_MISS",
                 "processes matching %s: 0\nREJECTED rows that NAME it: %s\n%s"
                 % (cmd, _near_ours_txt(pane_near), _pane_protection_txt(pane)),
                 "the scoped census matched nothing but rejected a process whose command names %s, "
                 "so 'the daemon is absent' is not established. Not green." % cmd)
    if not pids:
        return V("pane_daemon", FAIL, "DAEMON_ABSENT",
                 "processes matching %s: 0\n%s" % (cmd, _pane_protection_txt(pane)),
                 "no pane daemon: every lane's surface goes with it, and an OOM kill leaves the "
                 "supervising unit reading 'active'.")

    adj = [p.get("oom_score_adj") for p in pids]
    # ⛔ A BOOL IS NOT A READING. `is not None` treated `False`/`True` as READ and `False >= 0` is
    # true, so `oom_score_adj: true` produced `FAIL/PROTECTION_ABSENT` — a claim of measured
    # non-protection built from a boolean, on the one number whose misread delivers a message.
    # A non-number falls into `unread`, which is an abstention, never a FAIL.
    known = [a for a in adj if _is_age(a)]      # a score is a number, and a bool is not one
    pid_txt = ", ".join(str(p.get("pid")) for p in pids)
    prot_txt = _pane_protection_txt(pane)

    # ⛔ `is not True`, like every other bit in this file: `not pane.get("protection_supported")`
    # reads the string "false" (or "no", or 1) as SUPPORTED, so a payload saying the platform cannot
    # demonstrate protection graded `PASS/ALIVE_PROTECTED` — exit 0, no message — on the one check
    # whose stated reason to exist is that "alive" is not "protected".
    if pane.get("protection_supported") is not True:
        return V("pane_daemon", INCONCLUSIVE, "PROTECTION_UNEVALUABLE",
                 "%d live %s process(es) (pid %s)\n%s"
                 % (len(pids), cmd, pid_txt, prot_txt),
                 "the daemon is ALIVE, but no OOM-protection value is readable on this platform, so "
                 "'protected' is neither established nor refuted. Alive is not the same as "
                 "protected — the measured failure was an OOM kill with the unit still 'active'. "
                 "On Linux the value is /proc/<pid>/oom_score_adj; darwin exposes no equivalent, "
                 "so a Mac box has to demonstrate protection some other way. Not green.")
    # ⛔ `0` is EVERY process's default oom_score_adj: it is not protection. Only a NEGATIVE value
    # deprioritises the process (-1000, OOM_SCORE_ADJ_MIN, makes it immune), and treating `<= 0` as
    # protected made this check permanently green on Linux — the exact arm that must fire on
    # "cmux-tui was OOM-killed while the unit still read active" could never fire.
    # ⛔ AN UNREAD VALUE IS NOT A NEGATIVE ONE. `known` silently drops None (EACCES on another
    # user's /proc/<pid>/oom_score_adj, a timed-out probe — i.e. any canary not running as the
    # daemon's owner), and with every value unread this returned FAIL/PROTECTION_ABSENT: a claim of
    # absence built from a failed read. The doc reserves PROTECTION_UNEVALUABLE for exactly this.
    unread = len(known) < len(adj)
    protected = [a for a in known if a < 0]
    if not known:
        return V("pane_daemon", INCONCLUSIVE, "PROTECTION_UNEVALUABLE",
                 "%d live %s process(es) (pid %s)\noom_score_adj: %s — NO value could be read\n%s"
                 % (len(pids), cmd, pid_txt, adj, prot_txt),
                 "the daemon is alive but none of its oom_score_adj values could be READ, so "
                 "'protected' is neither established nor refuted. Not green.")
    if not protected and not unread:
        return V("pane_daemon", FAIL, "PROTECTION_ABSENT",
                 "%d live %s process(es) (pid %s)\noom_score_adj: %s\n%s"
                 % (len(pids), cmd, pid_txt, adj, prot_txt),
                 "the daemon is alive and NOT OOM-protected (oom_score_adj > 0 means the kernel "
                 "may kill it first). Being alive today is not protection.")
    # ⛔ A MEASURED VALUE OUTRANKS AN UNREAD SIBLING. `unread` returned unconditionally, so with one
    # pid READ as `oom_score_adj: 500` (the kernel may kill it first) and another unreadable, the
    # check abstained — an abstention speaking about a datum it DID read. Only an abstention that
    # has nothing measured to speak about is honest.
    unprotected_known = [a for a in known if a >= 0]
    if unprotected_known:
        return V("pane_daemon", FAIL, "PROTECTION_PARTIAL",
                 "%d live %s process(es) (pid %s)\noom_score_adj: %s\nprotected: %d of %d "
                 "(READ as unprotected: %s)\n%s"
                 % (len(pids), cmd, pid_txt, adj, len(protected), len(pids),
                    unprotected_known, prot_txt),
                 "at least one pane-daemon process was READ as unprotected (oom_score_adj >= 0), and "
                 "the unprotected one is the one an OOM kill takes.")
    if unread:
        # Some values were unreadable, so neither "all protected" nor "these are unprotected" holds.
        # ⛔ A DISTINCT NAME, because `Verdict.key` is `name|variant` and the notifier suppresses on
        # the key alone: sharing `PROTECTION_PARTIAL` with the FAIL below meant "protection could not
        # be proven" was delivered once and the later, ESTABLISHED "the daemon is NOT protected" was
        # never sent — and only a PASS clears the key, which an unprotected daemon never reaches.
        return V("pane_daemon", INCONCLUSIVE, "PROTECTION_PARTIAL_UNREAD",
                 "%d live %s process(es) (pid %s)\noom_score_adj: %s\nprotected: %d of %d, "
                 "%d UNREAD\n%s" % (len(pids), cmd, pid_txt, adj, len(protected), len(pids),
                                     len(adj) - len(known), prot_txt),
                 "at least one protection value could not be read, so the OOM arm is not "
                 "established for the whole daemon. Not green.")
    return V("pane_daemon", PASS, "ALIVE_PROTECTED",
             "%d live %s process(es) (pid %s)\noom_score_adj: %s\n%s"
             % (len(pids), cmd, pid_txt, adj, prot_txt))


PANE_INTERP = re.compile(r"^(?:ba|z|da|k|a)?sh$|^node$|^python3?(?:\.\d+)?$|^bun$|^deno$")


def pick_pane_daemon_pids(ps_out, name="cmux-tui"):
    """Every process that IS the pane daemon — and, separately, every process that merely MENTIONS it.

    ⛔ THE SAME UNSCOPED-SUBSTRING DEFECT THE CONTROLLER CENSUS WAS FIXED FOR, THREE TIMES OVER, left
    open here: a substring match on the whole command line counted `tail -f ~/.cmux/cmux-tui.out` and
    `less …/cmux-tui.log` as the daemon. Those are exactly the processes an operator creates by
    following this check's own NEXT COMMAND (`pgrep -fl cmux-tui`), and the fleet deprioritises lanes,
    so they inherit a negative `oom_score_adj` and the check read **ALIVE_PROTECTED** while the daemon
    that carries every lane's surface did not exist. Two processes are the daemon: the binary itself,
    and an interpreter running it as its FIRST argument. Everything else is a near-miss, returned as
    evidence so "no daemon" does not look like "there was nothing to see".

    Input is `ps -Ao pid=,command=` (pid, then the command); returns ([{pid, cmd}], [near-miss]).
    """
    rows, near = [], []
    for line in ps_out.splitlines():
        line = line.strip()
        if name not in line:
            continue
        parts = line.split(None, 1)
        if len(parts) < 2 or not parts[0].isdigit():
            continue
        pid, cmd = int(parts[0]), parts[1]
        toks = cmd.split()
        if not toks:
            continue
        base0 = os.path.basename(toks[0])
        is_daemon = (base0 == name
                     or (len(toks) > 1 and os.path.basename(toks[1]) == name
                         and PANE_INTERP.match(base0) is not None))
        if is_daemon:
            rows.append({"pid": pid, "cmd": cmd[:300]})
        else:
            near.append({"pid": pid, "cmd": cmd[:300]})
    return rows, near


def _pane_protection_txt(pane):
    near = pane.get("near_misses") or []
    if near:
        # Evidence, not decoration: a census that rejected something must say so, or "0 daemons"
        # looks identical to "there was nothing to look at".
        return "REJECTED (mentioned the name, is not the daemon): %s" % ", ".join(
            "%s %s" % (n.get("pid"), (n.get("cmd") or "")[:60]) for n in near[:5])
    # ⛔ `is True`, like the verdict above it. Graded by truthiness, the string "false" — "this
    # platform cannot demonstrate protection" — selected the oom_score_adj line, so the delivered
    # evidence said protection WAS readable directly under a verdict saying it was not, and the
    # payload's own `protection_note` was never printed.
    if pane.get("protection_supported") is True:
        return ("protection source: %s (negative = deprioritised; -1000 = immune; 0 is the "
                "DEFAULT and protects nothing)" % (pane.get("protection_source") or "oom_score_adj"))
    return "protection source: NONE READABLE (%s)" % (
        pane.get("protection_note") or "no oom_score_adj on this platform")


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Check 7 — headroom (disk / memory), with the numbers
# ════════════════════════════════════════════════════════════════════════════════════════════════


def check_headroom(f, c):
    hr = f.get("headroom") or {}
    disk = hr.get("disk") or {}
    mem = hr.get("mem") or {}
    lines = []
    bad = []
    unknown = []

    # ⛔ AN `ok` READ WITH NO NUMBER IS NOT 0 GiB. `(avail_bytes or 0)` turned a missing field into
    # "disk 0.0 GiB free" — a manufactured OOM emergency on the check whose FAIL must mean one. Same
    # defect as the `vm_stat` arm; the surface is UNREAD, so it belongs in `unknown`.
    # ⛔ `isinstance(True, int)` IS TRUE: a boolean `avail_bytes`/`avail_mb` was divided and
    # subtracted as a number and manufactured `FAIL/BELOW_FLOOR` ("0.0 GiB free", "1 MiB available")
    # — a fake OOM emergency on the check whose FAIL must mean one. Same polarity as the PR counts.
    # ⛔ `disk.get("ok")` IS TRUTHINESS, and the string "false" is truthy: a surface that said the
    # read FAILED was graded as a successful one carrying `avail_bytes: 0` and manufactured
    # `FAIL/BELOW_FLOOR` ("0.0 GiB free") — the fake OOM emergency these two arms exist to prevent,
    # reached through the polarity shape they left. Every other reader in this file uses `is True`.
    if disk.get("ok") is True and not _is_age(disk.get("avail_bytes")):
        lines.append("disk: READ ok but NO avail_bytes field (%r)" % (disk.get("avail_bytes"),))
        unknown.append("disk")
    elif disk.get("ok") is True:
        gb = disk["avail_bytes"] / float(1 << 30)
        # a MISSING `used_pct` is printed as not-measured, never as "-1.0% used"
        used_txt = ("%.1f%% used" % disk["used_pct"]) if _is_age(disk.get("used_pct")) \
            else "used_pct not read"
        lines.append("disk: %.1f GiB free (%s) on %s — floor %.1f GiB"
                     % (gb, used_txt, disk.get("mount") or "/", c.disk_floor_gb))
        if gb < c.disk_floor_gb:
            bad.append("disk %.1f GiB < %.1f GiB" % (gb, c.disk_floor_gb))
    else:
        lines.append("disk: UNREADABLE (%s)" % (disk.get("error") or "?"))
        unknown.append("disk")

    # ⛔ THE DISK ARM'S TWIN: `(avail_mb or 0)` manufactures "0 MiB available" out of a field that
    # was never read, i.e. an OOM emergency on the check whose FAIL must mean one.
    if mem.get("ok") is True and not _is_age(mem.get("avail_mb")):
        lines.append("memory: READ ok but NO avail_mb field (%r)" % (mem.get("avail_mb"),))
        unknown.append("memory")
    elif mem.get("ok") is True:
        mb = mem["avail_mb"]
        lines.append("memory: %.0f MiB available — floor %.0f MiB (source: %s)"
                     % (mb, c.mem_floor_mb, mem.get("source") or "?"))
        if mb < c.mem_floor_mb:
            bad.append("memory %.0f MiB < %.0f MiB" % (mb, c.mem_floor_mb))
    else:
        lines.append("memory: UNREADABLE (%s)" % (mem.get("error") or "?"))
        unknown.append("memory")

    ev = "\n".join(lines)
    if bad:
        return V("headroom", FAIL, "BELOW_FLOOR", ev,
                 "below the configured floor: %s. This throttles or kills lanes, and an OOM kill "
                 "takes the pane daemon first." % "; ".join(bad))
    if unknown:
        return V("headroom", INCONCLUSIVE, "PROBE_UNREADABLE", ev,
                 "could not read %s, so headroom is not established. Not green."
                 % " and ".join(unknown))
    return V("headroom", PASS, "HEADROOM_OK", ev)


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Check 8 — every green, mergeable PR has an armed lander (or is railed)
# ════════════════════════════════════════════════════════════════════════════════════════════════

# ⛔ "NOT RED", NOT "PASSED" — the merge rail's polarity (`cancelled`/`stale` are non-red there).
# Read `rollup_state`'s docstring: `checks_green` answers "may this merge on checks", never "CI passed".
GREEN_CONCLUSIONS = ("SUCCESS", "NEUTRAL", "SKIPPED", "CANCELLED", "STALE")


def rollup_state(rollup):
    """The three-way READ of a check rollup: "green", "red", "inflight", or None (unreadable).

    ⛔ THE DISTINCTION EXISTS BECAUSE THE LABEL IS A CLAIM. `landers` prints a skip line per PR it will
    not land, and calling an in-flight check "red" asserts a conclusion nobody has reached — a
    QUEUED check-run awaiting approval or a `PENDING` legacy context stays in flight for hours, and a
    CLEAN, APPROVED, UNARMED PR was reported as known-not-landable `:red` inside a PASS block. The
    VERDICT is unchanged (an in-flight PR is not landable yet); only the claim made about it is.
    """
    if not isinstance(rollup, list) or not rollup:
        return None
    attempts = {}
    for pos, chk in enumerate(rollup):
        if not isinstance(chk, dict):
            return None
        attempts.setdefault(_check_key(chk), []).append((_check_rank(chk, pos), chk))
    # ⛔ A CONCLUDED RED OUTRANKS AN IN-FLIGHT CHECK, whatever order the groups arrive in. Returning
    # on the first in-flight group made the answer depend on dict ordering: `[red, queued]` said "red"
    # and `[queued, red]` said "inflight", so a PR with a FAILED check was labelled `:inflight`. The
    # verdict is unaffected (neither is landable) but the LABEL is a claim.
    seen_inflight = False
    for _key, entries in attempts.items():
        # ⛔ THE NEWEST ATTEMPT PER CHECK DECIDES — AND THAT INCLUDES THE IN-FLIGHT ARM. Asking
        # `any(_in_flight(...))` over the WHOLE group let a SUPERSEDED queued attempt outrank a newer
        # concluded one (the repo's own rule is that a re-run ADDS a row, it does not clear one, so
        # co-residence is the normal shape). Measured: a check with a stale QUEUED attempt beside a
        # newer SUCCESS read "inflight"/not-green, so `landers` skipped a CLEAN, APPROVED, unarmed PR
        # as `:inflight` and returned PASS/NOTHING_GREEN — the false green this check exists for.
        #
        # ⛔ BUT AN UNORDERABLE IN-FLIGHT ATTEMPT STILL ABSTAINS. A queued check-run carries no
        # `startedAt` (and GraphQL carries no `id`), so it ranks by LIST POSITION — grading the other
        # attempt on its timestamp would silently treat a genuinely NEWER queued attempt as the older
        # one and publish the previous attempt's verdict. Unknown ordering is not a newer green.
        if any(_in_flight(chk) and e[0] == 0 and e[2] == 0.0 for e, chk in entries):
            seen_inflight = True
            continue
        _rank, chk = max(entries, key=lambda e: e[0])
        if _in_flight(chk):
            seen_inflight = True
            continue
        concl = _check_conclusion(chk)
        if concl is None:
            seen_inflight = True
            continue
        if concl not in GREEN_CONCLUSIONS:
            return "red"
    return "inflight" if seen_inflight else "green"


def rollup_is_green(rollup):
    """Is this PR's rollup green — ONE verdict per CHECK, from its NEWEST attempt.

    ⛔ The rollup is a LIST OF ATTEMPTS, not a list of checks. A flaky job that failed and then
    passed on re-run appears TWICE, so a flat "every entry must be green" walk reads that commit RED
    — and a red-reading green PR silently drops out of the `landers` population, which is a false
    green on the one check that exists to catch a lander expiring on a PR nobody looked at. (The
    repo-wide rule: a re-run ADDS a red, it does not clear one.)
    So attempts are grouped and only the newest per group is graded. ⛔ GROUPING IS
    `(workflowName | actions-run id | app.slug, name)` — the merge rail's `(app, name)` key is
    deliberately NOT reused, because it merges two workflows that share a job name (measured:
    `changes` is published by both `CI` and `Python CI`), and a shared job name is exactly how a
    red check gets masked by a green one. See `_check_key`; the rail's conflation is its own
    declared residual, referenced there and not inherited here.
    Newest attempt = highest `id` (`started_at` is nullable and `completed_at` can tie). Where a
    surface supplies no ids (a legacy status context), later list position wins.

    ⛔ WHAT "GREEN" MEANS HERE: **not red**. `success`/`neutral`/`skipped` are green, and
    `cancelled`/`stale` are treated as NON-RED — deliberately, because this predicate answers "is
    there a failing check blocking a merge", which is the merge rail's own polarity
    (`scripts/admin-merge.sh` treats `{success, neutral, skipped, cancelled, stale}` as non-red).
    EVERY OTHER CONCLUSION — including one GitHub has not documented, and a null one — is RED. A
    check that was CANCELLED therefore reads `checks_green: True`; that is "nothing here blocks a
    merge", not "CI passed", and the two are kept distinct by this sentence rather than by a name. A missing check is not a green check — and an EMPTY/absent rollup is not "not green"
    either: it is `None`, meaning NO CHECK SURFACE WAS READ.
    """
    # ⛔ ONE GRADING IMPLEMENTATION. This function is the BOOLEAN PROJECTION of `rollup_state`, which
    # holds the grouping and the polarity; a second copy of that logic is how an in-flight check was
    # graded red here while `rollup_state` (added later) answered "inflight" for the same rollup.
    state = rollup_state(rollup)
    if state is None:
        return None          # no check surface read at all — a MISSING READ, not a verdict
    return state == "green"


RE_ACTIONS_RUN = re.compile(r"/actions/runs/(\d+)")


def _run_id_of(url):
    """The actions RUN id from a check-run's `details_url` — the identity a re-run does NOT change.

    A re-run keeps the run and bumps its attempt, whereas each attempt may get a new CHECK SUITE, so
    the run id groups attempts together without shattering one check per attempt.
    """
    m = RE_ACTIONS_RUN.search(str(url or ""))
    return m.group(1) if m else ""


def _check_key(chk):
    """(workflow, check name) — what makes two entries THE SAME CHECK.

    ⛔ MEASURED ON THE LIVE SURFACE: `gh pr list --json statusCheckRollup` emits
    `__typename, name, workflowName, status, conclusion, startedAt, completedAt, detailsUrl` — there
    is NO `app` and NO `id`. Keying on `app` therefore collapsed EVERY workflow into one group, so
    `changes` (published by both `CI` and `Python CI`) and `ai-review-gate` (measured twice with
    DIFFERING conclusions on the same PR) were graded as one check, and an arbitrary one of the two
    decided the PR. `workflowName` is the discriminator that exists; `app.slug` is the fallback the
    REST check-runs payload offers, and an entry with neither is grouped alone rather than dropped
    (an ungrouped check would escape the verdict).
    """
    wf = str(chk.get("workflowName") or "")
    if not wf:
        # ⛔ THE REST SURFACE HAS NO `workflowName`, so keying on `app.slug` re-introduced the exact
        # collapse the GraphQL fix removed: measured on one commit, `changes` is published by TWO
        # workflows (suite …05368 and …06121), both `app=github-actions`, so one group held both and
        # a sibling's red `changes` was masked by the other's green. The actions RUN id in
        # `details_url` distinguishes them and survives a re-run (the run is reused, the attempt is
        # not), so the newest attempt still wins inside a group.
        wf = _run_id_of(chk.get("details_url") or chk.get("detailsUrl") or "")
    if not wf:
        a = chk.get("app")
        if isinstance(a, dict):
            wf = str(a.get("slug") or "")
        elif isinstance(a, str):
            wf = a
    name = chk.get("name")
    if name in (None, ""):
        name = chk.get("context")
    return (wf, str(name) if name is not None else "")


def _iso_epoch(v):
    """ISO-8601 → epoch seconds, or None. `Z` is normalised first: `datetime.fromisoformat` rejects it
    before python 3.11, and CI runs 3.12 while a dev box may run 3.9."""
    if not isinstance(v, str) or not v.strip():
        return None
    t = v.strip()
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    try:
        return datetime.datetime.fromisoformat(t).timestamp()
    except Exception:
        return None


def _check_rank(chk, pos):
    """Newest attempt LAST, per surface.

    A check-run `id` is monotonic and therefore the honest ordering — but REST is the ONLY surface
    that carries one. GraphQL carries timestamps instead, and its list order is NOT chronological
    (measured: 18 of 59 adjacent pairs have a later position with an earlier `startedAt`), so "last
    in the list wins" picks arbitrarily on real data. Order: id where present, else the latest of
    completed/started, else list position.
    """
    ident = chk.get("id")
    if _is_count(ident):
        return (1, float(ident), 0.0, pos)
    ts = 0.0
    for key in ("completedAt", "completed_at", "startedAt", "started_at"):
        e = _iso_epoch(chk.get(key))
        if e is not None and e > ts:
            ts = e
    return (0, 0.0, ts, pos)


def _in_flight(chk):
    """Has this attempt concluded? A check run's `status` is COMPLETED or not; a legacy status context
    answers `state == PENDING`. Absent means "not stated" — the conclusion is then graded directly."""
    st = chk.get("status")
    if isinstance(st, str) and st.strip():
        return st.strip().upper() != "COMPLETED"
    state = chk.get("state")
    return isinstance(state, str) and state.strip().upper() == "PENDING"


def _check_conclusion(chk):
    """The conclusion, normalised across check runs (`conclusion`) and status contexts (`state`).
    A status context has no `conclusion`, so reading only `conclusion` graded every legacy context
    RED and dropped that PR from the lander population."""
    for key in ("conclusion", "state"):
        v = chk.get(key)
        if v not in (None, ""):
            return str(v).upper()
    return None


MERGEABLE_STATES = ("CLEAN",)
# The mergeability states that mean "known, and not mergeable" — `BEHIND` for a branch main has moved
# past, `BLOCKED` for a required review or check, `DIRTY` for a conflict, `DRAFT`, `HAS_HOOKS` and
# `UNSTABLE` (a failing check). Anything else — including an ABSENT or unrecognised value — is a PR
# this check cannot grade, and it must reach `unprobed` rather than silently leaving the population.
KNOWN_NON_MERGEABLE = ("BLOCKED", "BEHIND", "DIRTY", "DRAFT", "HAS_HOOKS", "UNSTABLE")

# The states a REST/GraphQL response can carry that mean "mergeability is NOT KNOWN YET" (GraphQL
# documents `mergeStateStatus: UNKNOWN` while it computes). Such a PR must be reported as UNPROBED so
# it reaches PARTIAL_POPULATION — dropping it silently is how a green PR with an expired lander
# disappears.
MERGEABILITY_UNKNOWN = ("", "UNKNOWN")

# Review decisions known by name to mean "not landable yet". Anything else in `review_decision` is a
# state this tool has never seen, so the PR is unprobed rather than dropped: a green, mergeable,
# unarmed PR that vanishes from the population is exactly the failure this check exists for.
KNOWN_NON_MERGEABLE_REVIEWS = ("CHANGES_REQUESTED", "REVIEW_REQUIRED", "DISMISSED")


def check_landers(f, c):
    gh = f.get("github") or {}
    if gh.get("ok") is not True:
        return V("landers", INCONCLUSIVE, "GH_UNREADABLE",
                 "gh: %s" % (gh.get("error") or "call failed"),
                 "the open-PR population could not be read, so 'every green PR has an armed "
                 "lander' is not established. Not green.")

    prs = gh.get("open_prs")
    # ⛔ `gh.get("open_prs") or []` turned an ABSENT key into "zero open PRs", and `ok is True` was
    # the only gate — so a payload with `ok: true` and no rows made `landers` ASSERT "every green PR
    # has an armed lander" over a population it never read, while the contradicting `open_pr_count`
    # sat in the same dict unread. Missing rows, and a count that disagrees with them, are both a
    # failed read.
    if not isinstance(prs, list):
        return V("landers", INCONCLUSIVE, "GH_UNREADABLE",
                 "gh: ok but NO `open_prs` list in the payload (keys: %s)"
                 % ", ".join(sorted(gh.keys())),
                 "the open-PR population is absent from the payload, so 'every green PR has an armed "
                 "lander' would be asserted over nothing. Not green.")
    if (not _is_count(gh.get("open_pr_count"))
            or gh["open_pr_count"] != len(prs)):
        return V("landers", INCONCLUSIVE, "GH_UNREADABLE",
                 "gh: open_pr_count=%r but %d row(s) were returned"
                 % (gh.get("open_pr_count"), len(prs)),
                 "the payload disagrees with itself about how many open PRs exist, so the population "
                 "is not established. Not green.")
    events = f.get("log_events") or {}
    # ⛔ A DECISION IN THE LOG IS A DECISION *NOW* — an unaged one is not.
    # `#N PENDING (rail mode …)` printed last night kept a green PR reading "railed" long after the
    # rail was abandoned, and a fixture-less event (unparseable enclosing header ⇒ no `age_s`) was
    # read as fresh. Both are a PASS on a lander that does not exist, so decisions are filtered by
    # age before they count. The bound is the PR-scale window (`pr_window_s`), not the 3-cycle
    # `window_s`: a rail legitimately persists for hours, and a 12-minute bound would fail every
    # green PR on the box.
    # ⛔ A DECISION WRITTEN BY ANOTHER REPO'S CONTROLLER IS NOT A LANDER FOR THIS REPO'S PR. A
    # mismatch does not invalidate the GITHUB facts (which are read for `c.repo`), only the log's
    # decisions — so it unprobes the candidates that need one and never invents a claim about a PR it
    # did read. `PASS/NOTHING_GREEN` is untouched: "no PR is green+mergeable" needs no log at all.
    log_repo = _log_repo_of(f)
    repo_mismatch = bool(log_repo and c.repo and log_repo.lower() != c.repo.lower())
    armed_log = _in_window(events.get("armed"), c.pr_window_s)
    railed_log = _in_window(events.get("railed"), c.pr_window_s)
    stale_log = ((_decisions(events.get("armed")) | _decisions(events.get("railed")))
                 - (armed_log | railed_log))

    candidates, unprobed, skipped, unprobed_reasons = [], [], [], []
    non_draft = 0
    for pr in prs:
        # ⛔ ONLY `True` IS A DRAFT, AND ABSENCE IS NOT `False`. `if pr.get("draft")` read the string
        # "false" (or `"no"`, or `1`) as DRAFT-or-not by truthiness — silently removing a live PR
        # from the population — while `.get("draft", False)` read a MISSING key as a definite
        # non-draft, so a row that might be a draft produced `FAIL/LANDER_MISSING` ("this PR has no
        # lander"). Both are the polarity defect `checks_green` and `auto_armed` below were fixed
        # for, and every sibling field two lines below already abstains on absence.
        draft = pr.get("draft")
        if draft is True:
            # ⛔ COUNTED like every other known skip. A draft was dropped with no line at all, so the
            # population arithmetic did not reconcile (measured: `open PRs: 54`, `skipped: 25`,
            # `unprobed: 28` — one row unaccounted for) and `DRAFT` in KNOWN_NON_MERGEABLE was
            # unreachable, because this `continue` fired first.
            skipped.append("%s:DRAFT" % (pr.get("number"),))
            continue
        # ⛔ THE DENOMINATOR IS "EVERY OPEN ROW THAT IS NOT A DEFINITE DRAFT", so it is incremented
        # BEFORE the unread-bit abstention: that row is in `unprobed` too, and counting it only after
        # the `continue` produced "2 of 1 non-draft open PR(s) could not be probed".
        non_draft += 1
        if not isinstance(draft, bool):
            unprobed.append(pr.get("number"))
            unprobed_reasons.append("%s: the draft bit is %s, which is not a bool"
                                    % (pr.get("number"),
                                       "ABSENT" if "draft" not in pr else repr(draft)))
            continue
        mss, green = pr.get("merge_state_status"), pr.get("checks_green")
        # ⛔ "GRADED OR UNPROBED, NEVER NEITHER" — enforced HERE, not only in the collectors.
        # `pr.get("probed", True)` read an ABSENT key as `True` (every fixture omitted it), and a row
        # the filters below could not grade — no mergeability, no check surface — left BOTH lists, so
        # an unread PR vanished from a PASS. A missing input is a missing read: abstain.
        if (pr.get("probed") is not True or green is None
                or (mss not in MERGEABLE_STATES and mss not in KNOWN_NON_MERGEABLE)):
            unprobed.append(pr.get("number"))
            if pr.get("unprobed_reason"):
                unprobed_reasons.append("%s: %s" % (pr.get("number"), pr.get("unprobed_reason")))
            continue
        if mss not in MERGEABLE_STATES:
            # A KNOWN non-mergeable state is skipped — but COUNTED and printed, or `landers` reads
            # PASS over a population it silently discarded (measured: EVERY open PR on this box was
            # BLOCKED or DIRTY, so the check graded nothing at all while reporting health).
            skipped.append("%s:%s" % (pr.get("number"), mss))
            continue
        # ⛔ ALLOW-LIST POLARITY: `if not green` reads the string "false" (or `"no"`, or `1`) as
        # GREEN, so a collector regression or a hand-written facts file published `PASS/LANDERS_ARMED`
        # for a PR whose own evidence line printed `green=false`. Only `True` is green here; `None`
        # is already an unprobed row (handled above).
        if green is not True:
            # ⛔ NAME THE REASON THE ROW CARRIES. A not-green PR is skipped either because a check
            # CONCLUDED red or because one is still IN FLIGHT, and `:red` asserted the first for both.
            skipped.append("%s:%s" % (pr.get("number"), pr.get("checks_state") or "red"))
            continue
        rd = pr.get("review_decision")
        if rd not in (None, "", "APPROVED"):
            if str(rd).upper() in KNOWN_NON_MERGEABLE_REVIEWS:
                skipped.append("%s:%s" % (pr.get("number"), str(rd).upper()))
                continue
            # an UNRECOGNISED review decision is not a reason to forget the PR
            unprobed.append(pr.get("number"))
            continue
        candidates.append(pr)

    skip_txt = ""
    if skipped:
        # ⛔ BUILT HERE, not after the candidate block: the `NOTHING_GREEN` return below happens
        # BEFORE that line, so a population discarded for a known reason was invisible — the check
        # reported "no lander is expected" over PRs it had thrown away.
        skip_txt = ("skipped (known, not landable): %d — %s"
                    % (len(skipped), ", ".join(skipped[:12]) + (" …" if len(skipped) > 12 else "")))

    # ⛔ AN ABSENT FLAG IS NOT A COMPLETE POPULATION WHEN THE BOUND IS REACHED. `gh.get("page_full")`
    # read a payload that never said so as complete, so 100 rows with no disclosure graded as a whole
    # population — the polarity the collector states two functions away ("unprovable coverage is
    # truncated, never 'complete'"). The bound is MATERIAL only when it is reached: a 1-row payload
    # cannot have been cut by a 100-row page, so absence there is not evidence of truncation either.
    # ⛔ TRUNCATION IS AN ABSTENTION ABOUT THE PAGE THAT WAS NEVER FETCHED, so it must not silence a
    # fact measured on a row that WAS read: `expired` is a per-PR observation (a fresh `[armed] #N`
    # line plus `auto_armed: false` on a row in hand). It was graded before `expired`/`missing` were
    # even computed, so a truncated population turned the FAIL this check exists for into exit 2.
    truncated = gh.get("page_full") is True or (gh.get("page_full") is None and len(prs) >= 100)

    if not candidates and truncated:
        # …but with NO candidate row at all there is nothing to grade, and "none of the PRs I saw is
        # green" says nothing about the page that was never fetched.
        return V("landers", INCONCLUSIVE, "PARTIAL_POPULATION",
                 "open PRs: %d — POPULATION TRUNCATED at the gh page bound, so PRs beyond it were "
                 "never read\n%s\n%s"
                 % (len(prs), _gh_surface_txt(gh), _prs_brief(prs)),
                 "the open-PR list came back full, so the population is TRUNCATED and 'every green "
                 "PR has an armed lander' cannot be established over it. Not green.")

    if not candidates:
        if unprobed:
            return V("landers", INCONCLUSIVE, "PARTIAL_POPULATION",
                     "open PRs: %d, unprobed (never read: no check surface, a failed probe, "
                     "mergeability unknown, or beyond the probe bound): %s\n%s\n%s%s"
                     % (len(prs), unprobed, _gh_surface_txt(gh), _prs_brief(prs),
                        ("\nwhy (from the payload): %s" % "; ".join(unprobed_reasons[:8]))
                        if unprobed_reasons else ""),
                     "%d open PR(s) could not be probed (the REST fallback is bounded), so "
                     "'every green PR has an armed lander' is not established over the whole "
                     "population. Not green." % len(unprobed))
        return V("landers", PASS, "NOTHING_GREEN",
                 "open PRs: %d\nnone is green+mergeable (no lander is expected)\n%s\n%s%s"
                 % (len(prs), _gh_surface_txt(gh), _prs_brief(prs),
                    ("\n" + skip_txt) if skip_txt else ""),
                 "")

    expired, missing, ok = [], [], []
    for pr in candidates:
        n = pr.get("number")
        # ⛔ ONLY `True` IS ARMED, AND AN ABSENT KEY IS NOT `False`. Two defects in one line:
        # `pr.get("auto_armed")` read a MISSING key as a negative and produced `FAIL/LANDER_MISSING`
        # from a value the payload never carried — indistinguishable from a real read of
        # `autoMergeRequest: null` — while the string "false" was TRUTHY and published
        # `PASS/LANDERS_ARMED` for a PR whose own evidence line printed `armed=false`. That is the
        # polarity defect fixed directly above for `checks_green`, in the ONE check whose purpose is
        # catching a silent lander expiry, so ONE allow-list test covers both shapes: a bool or an
        # abstention, never a guess.
        armed_bit = pr.get("auto_armed")
        if not isinstance(armed_bit, bool):
            unprobed.append(n)
            unprobed_reasons.append("%s: auto_armed is %s, which is not a bool"
                                    % (n, "ABSENT" if "auto_armed" not in pr else repr(armed_bit)))
            continue
        if armed_bit:
            ok.append(n)
        elif n in railed_log and not repo_mismatch:
            ok.append(n)          # rail mode: `--auto` is deliberately NOT armed by design
        elif n in armed_log and not repo_mismatch:
            # The LOG says a lander was armed and GitHub says it is not armed now. That is the
            # silent expiry: the lander went away and nothing said so.
            expired.append(n)
        else:
            missing.append(n)

    ev = ["open PRs: %d, green+mergeable: %d" % (len(prs), len(candidates)),
          _gh_surface_txt(gh),
          "armed/railed: %s" % (sorted(ok) if ok else "none")]
    if repo_mismatch:
        ev.append("⛔ THE LOG BELONGS TO ANOTHER REPO (%s) — its armed/railed decisions were NOT "
                  "counted for %s; only GitHub's own autoMergeRequest was. Grade with a --repo the "
                  "cell actually runs." % (log_repo, c.repo or "(no repo)"))
    if unprobed:
        # ⛔ NOT a footnote. `_collect_rest` stops probing at `rest_probe_max`, and a failed
        # check-runs call also yields probed=False, so on a box where GraphQL is exhausted this is
        # 15 of 40 PRs. A probed-and-armed PR used to end the question: the verdict was PASS and the
        # unread PRs appeared NOWHERE — a false green on the one check that exists to catch a lander
        # expiring on a PR nobody looked at.
        ev.append("UNPROBED (never read: no check surface, mergeability unknown, or beyond the "
                  "probe bound): %s" % unprobed)
        if unprobed_reasons:
            ev.append("why (from the payload): %s" % "; ".join(unprobed_reasons[:8]))
    if expired:
        ev.append("ARMED IN THE LOG, NOT ARMED IN GITHUB (expired): %s" % sorted(expired))
    if missing:
        ev.append("NEVER ARMED AND NOT RAILED: %s" % sorted(missing))
    if skip_txt:
        ev.append(skip_txt)
    if stale_log:
        # Not a footnote: these are the PRs whose only "lander" is an entry too old (or too
        # un-ageable) to be a current decision. Saying so is what separates "there is no lander"
        # from "the log mentions one and we refused to believe it".
        ev.append("DECISION TOO OLD OR UNAGED (not counted as a lander): %s" % sorted(stale_log))
    ev.append(_prs_brief(candidates))

    evidence = "\n".join(ev)
    if expired:
        return V("landers", FAIL, "LANDER_EXPIRED", evidence,
                 "%d green PR(s) had a lander recorded in the orchestrator log and NO armed "
                 "auto-merge in GitHub now: the lander expired silently and the PR waits for a "
                 "human. This is the exact failure this check exists for." % len(expired))
    if missing:
        return V("landers", FAIL, "LANDER_MISSING", evidence,
                 "%d green, mergeable PR(s) have no lander at all — neither an armed auto-merge "
                 "nor a rail-mode PENDING decision%s."
                 % (len(missing),
                    (" (the orchestrator log belongs to %s, so it could not vouch either — re-run "
                     "with the --repo this cell actually manages)" % log_repo) if repo_mismatch else ""))
    if truncated:
        # a measured FAIL has already been returned above; here the population is truncated and no
        # per-PR failure was observed, which is a PARTIAL read, never a PASS.
        return V("landers", INCONCLUSIVE, "PARTIAL_POPULATION", evidence,
                 "the open-PR list came back full, so the population is TRUNCATED: 'every green PR "
                 "has an armed lander' is established only for the rows that were read. Not green.")
    if unprobed:
        return V("landers", INCONCLUSIVE, "PARTIAL_POPULATION", evidence,
                 "%d of %d non-draft open PR(s) could not be probed, so 'every green PR has an "
                 "armed lander' is established for the rest but NOT for the whole population. "
                 "Not green." % (len(unprobed), non_draft))
    return V("landers", PASS, "LANDERS_ARMED", evidence)


def _decisions(bucket):
    """PR numbers named by a decision bucket (`armed` / `railed`)."""
    return set(r.get("pr") for r in bucket or [] if r.get("pr") is not None)


def _in_window(bucket, window_s):
    """The subset of a decision bucket young enough to be a CURRENT decision.

    An entry with NO `age_s` is excluded on purpose: the age is unknown (the enclosing cycle header
    was unparseable, or the record carries no timestamp), and an unknown age is a MISSING READ, not
    a fresh one — the same allow-list polarity the rest of this tool applies.
    """
    # ⛔ A BOOL IS NOT AN AGE, AND `None` IS NOT THE ONLY UNUSABLE ONE. `age_s: true` read as one
    # second and certified a stale `[armed]`/`[railed]` decision as CURRENT — `PASS/LANDERS_ARMED` on
    # the check whose whole purpose is the silent lander expiry.
    return set(r.get("pr") for r in bucket or []
               if r.get("pr") is not None
               and _is_age(r.get("age_s"))
               and r.get("age_s") <= window_s)


def _prs_brief(prs):
    rows = []
    for pr in prs[:12]:
        rows.append("  #%s merge_state=%s green=%s armed=%s review=%s"
                    % (pr.get("number"), pr.get("merge_state_status"),
                       pr.get("checks_green"), pr.get("auto_armed"),
                       pr.get("review_decision") or "-"))
    if len(prs) > 12:
        rows.append("  … %d more" % (len(prs) - 12))
    return "\n".join(rows) if rows else "  (none)"


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Evaluation — one pure pass over the facts
# ════════════════════════════════════════════════════════════════════════════════════════════════

PREDICATES = {
    "controller_cycling": check_controller_cycling,
    "queue_readable": check_queue_readable,
    "work_dispatched": check_work_dispatched,
    "pr_created": check_pr_created,
    "pr_merged": check_pr_merged,
    "pane_daemon": check_pane_daemon,
    "headroom": check_headroom,
    "landers": check_landers,
}


def evaluate(facts, cfg, only=None):
    """Run every predicate over `facts`. Pure: no clock, no I/O, no mutation."""
    out = []
    for name in CHECK_ORDER:
        if only and name not in only:
            continue
        try:
            out.append(PREDICATES[name](facts, cfg))
        except Exception as exc:   # a crashing predicate is INCONCLUSIVE, never a silent pass
            out.append(V(name, INCONCLUSIVE, "PREDICATE_ERROR",
                         "%s while evaluating %s" % (type(exc).__name__, name),
                         "the check itself raised (%s). An unevaluable check must never read as "
                         "green." % exc))
    return out


def exit_code(verdicts, not_evaluated=()):
    if any(v.status == FAIL for v in verdicts):
        return 1
    if any(v.status == INCONCLUSIVE for v in verdicts):
        return 2
    if not_evaluated:
        # ⛔ A CHECK THAT WAS NEVER EVALUATED IS NOT A PASS. `--live --only headroom` evaluated one
        # check, printed "summary: 1 PASS · 0 FAIL · 0 INCONCLUSIVE → exit 0" and exited 0 while
        # seven outcomes were unprobed — the contract this file states about itself ("an unevaluable
        # check must never read as green"), and the rule `--static` already applies by listing what
        # it did not assert.
        return 2
    return 0


# ════════════════════════════════════════════════════════════════════════════════════════════════
# The signal — message composition, de-duplication, delivery
# ════════════════════════════════════════════════════════════════════════════════════════════════

STATE_VERSION = 1


def default_state_path():
    """The notification STATE FILE. It is a file, not the directory: `State.save` replaces it
    atomically, and a path that is sometimes a directory and sometimes a file fails in the one place
    that only runs when something is already wrong (measured: the first live run died on save)."""
    base = os.environ.get("OUTCOME_CANARY_STATE") or os.path.join(
        os.path.expanduser("~"), ".pi", "agent", "state", "outcome-canary")
    return base if base.endswith(".json") else os.path.join(base, "state.json")


class State(object):
    """Per-box notification state: `notified[(check|VARIANT)] -> {at, …}`.

    The state is the SHAPE, not the numbers. Keying on evidence would make every log line a state
    change; keying on nothing would make the alert a timer. One message per shape, and a PASS on
    that check CLEARS the key so a re-break speaks again.
    """

    def __init__(self, path, box, persist=True):
        self.path = path
        self.box = box
        # ⛔ `--dry-run` MUST NOT PERSIST. `save()` is called from the DELIVERY path as well as at the
        # end of the run, so a guard at one call site is not enough — the delivery-path save is what
        # cleared a delivered key, re-arming an alert already sent (the next real poll then stacks a
        # second brief) and writing a `last_status` of all-PASS the box does not have. Reading is
        # untouched: a preview should still show what WOULD be sent.
        self.persist = bool(persist)
        self.data = {"version": STATE_VERSION, "boxes": {}}
        self.repaired = False
        try:
            with open(path) as fh:
                d = json.load(fh)
            if isinstance(d, dict) and isinstance(d.get("boxes"), dict):
                self.data = d
            else:
                # ⛔ EVERY shape that discards a pre-existing record is DISCLOSED. Only the per-box
                # case was flagged, so a file that parsed to `{"boxes": [1, 2]}` — or to anything
                # that is not a map — silently restarted de-duplication from empty, and the next
                # message repeated with no explanation.
                self.repaired = True
        except FileNotFoundError:
            pass
        except (ValueError, OSError):
            # an unparseable or unreadable state FILE is a discarded record too (the run continues on
            # an empty one, which is the alternative to crashing after the verdicts)
            self.repaired = True
        # ⛔ VALIDATE ONE LEVEL DEEPER. `isinstance(d.get("boxes"), dict)` checked only the outer
        # map, so a per-box value that is not a dict (a hand-edited file, an older format, a merged
        # state file, a `--state` pointed at the wrong path) raised `AttributeError: 'int' object has
        # no attribute 'setdefault'` AFTER the verdicts and BEFORE the report — exit 1 with 0 bytes
        # of output, which a scheduler reads as "a check FAILed" and the JSON is lost. That is the
        # exact failure the `save()` guard exists for; the reader had none.
        self.data.setdefault("boxes", {})
        repaired = self.repaired
        box_rec = self.data["boxes"].get(box)
        if not isinstance(box_rec, dict):
            # `None` here is either an absent key (nothing was discarded) or a JSON `null` (a record
            # was) — the two are not distinguishable from `.get`, so a present-but-null value counts.
            if box in self.data["boxes"]:
                repaired = True
            box_rec = {}
            self.data["boxes"][box] = box_rec
        # ⛔ EVERY DICT THIS RECORD CONSUMES, NOT JUST THE ONE THAT WAS THOUGHT OF. `ambiguous` was
        # read and written on every notify path with no shape check, so `{"ambiguous": 3}` in a
        # hand-edited/merged/older-format state file raised `TypeError: argument of type 'int' is not
        # iterable` in `is_ambiguous` — AFTER the verdicts and BEFORE the report, i.e. exit 1 with 0
        # bytes of output. And `{"ambiguous": ["x"]}` survived `is_ambiguous` only to raise
        # `pop expected at most 1 argument` on the DELIVERED path, which runs BEFORE `state.mark` and
        # `save()` — so a message that did land was never marked, and the next poll sent the same
        # brief again: the duplicated-brief failure the AMBIGUOUS default exists to prevent.
        # `captured` is the capture-mode twin of `notified`: it records that a message was WRITTEN
        # for this shape, never that it was SENT (see the notify loop). Kept in its own map so a
        # capture run can de-duplicate itself without ever silencing a live run that reads the same
        # file — the two are different claims.
        for key in ("notified", "ambiguous", "captured"):
            if not isinstance(box_rec.get(key), dict):
                if key in box_rec:
                    repaired = True
                box_rec[key] = {}
        self.repaired = repaired

    @property
    def notified(self):
        return self.data["boxes"][self.box]["notified"]

    def mark(self, key, when, delivered=True):
        self.notified[key] = {"at": when, "delivered": bool(delivered)}

    def clear(self, check):
        """A RECOVERY re-arms the alert — both halves of it.

        Clearing only the delivered keys leaves any AMBIGUOUS marker behind, and an ambiguous marker
        suppresses the shape it was recorded for. So: fail (send ambiguous) → recover → fail the same
        way again would be silent forever, which is the loudest possible failure of a notifier that
        is supposed to speak once per state change.
        """
        for k in list(self.notified):
            if k.split("|")[0] == check:
                del self.notified[k]
        cap = self.data["boxes"][self.box].get("captured") or {}
        for k in list(cap):
            if k.split("|")[0] == check:
                del cap[k]
        amb = self.data["boxes"][self.box].get("ambiguous") or {}
        for k in list(amb):
            if k.split("|")[0] == check:
                del amb[k]

    def mark_captured(self, key, when):
        self.data["boxes"][self.box].setdefault("captured", {})[key] = when

    def is_captured(self, key):
        return key in (self.data["boxes"][self.box].get("captured") or {})

    def mark_ambiguous(self, key, when):
        """Remember that this key's last attempt was AMBIGUOUS: suppress a blind retry until the shape
        changes (the key includes the variant, so a new shape re-arms automatically)."""
        self.data["boxes"][self.box].setdefault("ambiguous", {})[key] = when

    def is_ambiguous(self, key):
        return key in (self.data["boxes"][self.box].get("ambiguous") or {})

    def clear_ambiguous(self, key):
        (self.data["boxes"][self.box].get("ambiguous") or {}).pop(key, None)

    def clear_others(self, check, keep):
        """Drop this check's SIBLING keys once `keep` has been delivered.

        ⛔ Without this the notifier goes silent on a real state change: a failure that alternates
        between two non-PASS shapes (NOT_DISPATCHED -> NO_DISPATCH_GATED -> NOT_DISPATCHED) records
        one key per shape, so returning to the first shape matches an already-notified key and sends
        nothing — for good, until a full PASS clears the check. Measured by the reviewer on the
        shipped CLI. A delivered message supersedes every other shape of the same check.
        """
        for k in list(self.notified):
            if k != keep and k.split("|")[0] == check:
                del self.notified[k]
        cap = self.data["boxes"][self.box].get("captured") or {}
        for k in list(cap):
            if k != keep and k.split("|")[0] == check:
                del cap[k]
        # An AMBIGUOUS marker must be pruned the same way, or the suppression outlives the shape it
        # was recorded for: an attempt for NOT_DISPATCHED that may have landed would keep suppressing
        # that shape FOREVER, so the next time the fleet returns to it the alert is never sent — the
        # silence this method exists to prevent, one state further on.
        amb = self.data["boxes"][self.box].get("ambiguous") or {}
        for k in list(amb):
            if k != keep and k.split("|")[0] == check:
                del amb[k]

    def save(self):
        if not self.persist:
            return False          # a preview: the state was READ, never WRITTEN
        d = os.path.dirname(os.path.abspath(self.path)) or "."
        try:
            os.makedirs(d, exist_ok=True)
        except Exception:
            pass
        tmp = self.path + ".tmp.%d" % os.getpid()
        with open(tmp, "w") as fh:
            json.dump(self.data, fh, indent=1, sort_keys=True)
        os.replace(tmp, self.path)
        return True


def compose_message(v, verdicts, box, obs_iso, extra_lines=None):
    """A message that is ACTIONABLE or it is not sent.

    Required content, each of which has been absent from a real signal at some point: the failing
    CHECK, the EVIDENCE (log line, numbers, timestamps), an ORIENTATION pointer naming a SECTION,
    and the NEXT COMMAND.
    """
    lines = []
    lines.append("[fleet outcome canary] %s %s (%s) — box %s @ %s"
                 % (v.status, v.name, v.variant, box, obs_iso))
    lines.append("")
    lines.append("WHAT DID NOT PASS")
    lines.append("  %s — %s" % (v.name, v.detail or "the expected outcome is absent"))
    if v.status == INCONCLUSIVE:
        lines.append("  (INCONCLUSIVE is not a pass: this could not be evaluated, which must never")
        lines.append("   read as green. Treat it as unproven, not as healthy.)")
    lines.append("")
    lines.append("EVIDENCE")
    for ln in str(v.evidence).splitlines() or ["(none)"]:
        lines.append("  " + ln)
    others = [x for x in verdicts if x.name != v.name and x.status != PASS]
    if others:
        lines.append("")
        lines.append("ALSO NOT GREEN IN THIS RUN")
        for x in others:
            lines.append("  %s %s (%s)" % (x.status, x.name, x.variant))
    if extra_lines:
        lines.append("")
        lines.extend(extra_lines)
    lines.append("")
    lines.append("ORIENTATION")
    lines.append("  %s" % ORIENTATION.get(v.name, "scripts/orchestrator-harness/README.md"))
    lines.append("")
    lines.append("NEXT COMMAND")
    lines.append("  %s" % NEXT_COMMAND.get(v.name, "python3 tools/fleet/outcome_canary.py --live"))
    lines.append("")
    lines.append("(sent once per state change by tools/fleet/outcome_canary.py; it will not repeat"
                 " until the shape of this failure changes or it clears)")
    return "\n".join(lines) + "\n"


def plan_notifications(verdicts, state, capturing=False):
    """Which verdicts need a message. Change-only, per (box, check, variant).

    Returns (to_send, suppressed). A key is only recorded once a send is CONFIRMED, so a refused
    delivery is retried on the next poll instead of being silently marked "told them".
    """
    to_send, suppressed = [], []
    failing = [v for v in verdicts if v.status != PASS]
    for v in verdicts:
        if v.status == PASS:
            state.clear(v.name)          # a recovery re-arms the alert for that check
            continue
    for v in failing:
        # ⛔ A CAPTURE AND A SEND ARE DIFFERENT CLAIMS, so they de-duplicate against different maps.
        # Consulting `notified` in capture mode made a PREVIEW silence production; consulting
        # `captured` in send mode would make a real run repeat a message nobody has received yet.
        already = state.is_captured(v.key) if capturing else state.notified.get(v.key)
        if already or state.is_ambiguous(v.key):
            suppressed.append(v)
            continue
        # ⛔ NOTHING IS COMPOSED HERE. `main` composes the bytes it sends, extras included, and threw
        # this copy away — so a future edit to `compose_message` had two call sites where only one was
        # visible in the report. This function's job is WHICH verdicts to send, not what they say.
        to_send.append(v)
    return to_send, suppressed


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Delivery — the sanctioned path, never a bare `cmux send`
# ════════════════════════════════════════════════════════════════════════════════════════════════

# safe-send.sh's own contract, surfaced so a caller cannot mistake 3 for a delivered message.
# safe-send.sh's exit contract, READ FROM THE SCRIPT (scripts/safe-send.sh:150-190) and recorded
# here as the vocabulary its output is rendered with. It is NOT the classifier — see
# classify_send(): a hand-copied map is a second source of truth and it had already drifted (rc 5
# carries three meanings, two of them ambiguous-class, and a TIMEOUT is the canonical ambiguous case:
# the text may be in the composer while the caller knows nothing).
SAFE_SEND_RC = {0: "DELIVERED (consumed)", 3: "REFUSED (lane busy or state unknown)",
                1: "AMBIGUOUS (sent, not consumed)", 2: "usage/missing input",
                4: "AMBIGUOUS (sent, not consumed)", 5: "AMBIGUOUS (send state not established)",
                # ⛔ THE BRIEF GATE'S OWN CODES (#2258). Both are emitted BEFORE the pane is read, so
                # nothing was consumed and a retry is free — the same fact rc 3 carries. Without them
                # they fell through to the AMBIGUOUS default, which SUPPRESSES: one gate refusal was
                # enough to silence the fleet's alert path permanently (review cycle 5).
                78: "REFUSED (brief validator missing on this box)",
                80: "REFUSED (brief refused by the research-first gate)"}

# Phrases with which safe-send.sh says NOTHING was consumed. These are the only refusals that may be
# retried on the next poll; everything else non-zero is suppressed until the failure shape changes.
NOTHING_CONSUMED_PHRASES = (
    "Nothing consumed",          # rc 3 lane-guard refusal
    "Nothing was written",       # rc 5 FAILED-TO-START
    "no python3.12 found",       # rc 5 FATAL (no send attempted)
    "usage:",                    # rc 2
)


def classify_send(rc, out):
    """'delivered' | 'refused' | 'ambiguous' — one function, and AMBIGUOUS is the DEFAULT.

    ⛔ Polarity, not a list. `rc` values and message texts both drift; what must never drift is the
    asymmetry between the two mistakes:
      * retrying a REFUSED send is free (nothing was consumed);
      * retrying an AMBIGUOUS one STACKS A SECOND INSTRUCTION in a lane that may already hold the
        first (safe-send.sh's own words), which is the injected-double-brief failure it exists for.
    So an unrecognised rc, a timeout (127), or any message that does not positively say nothing was
    consumed is AMBIGUOUS. The cost of that default is a delayed alert; the cost of the other is a
    lane executing a duplicated brief.
    """
    out = out or ""
    if rc == 0:
        return "delivered"
    # ⛔ rc FIRST. The exit code is the contract; the text is a rendering of it. Keying on phrases
    # alone missed safe-send.sh's COMMONEST refusal — the lane-guard's rc 3, whose message says "Not
    # consumable" and never "Nothing consumed" — so a controller busy mid-turn got exactly ONE
    # attempt per failure shape and then permanent silence, while nothing had been consumed and a
    # retry was free. (The same "the tool holds the datum and does not read it" class as the census.)
    if rc in (2, 3, 78, 80):
        # 78/80 are the brief gate's: safe-send.sh exits them BEFORE it probes the pane, so nothing was
        # consumed (the same reasoning as rc 3, and the same bug class: an unlisted refusal code is
        # silently promoted to AMBIGUOUS, i.e. suppressed forever).
        return "refused"
    if any(ph.lower() in out.lower() for ph in NOTHING_CONSUMED_PHRASES):
        return "refused"
    if "AMBIGUOUS" in (SAFE_SEND_RC.get(rc) or ""):
        return "ambiguous"
    return "ambiguous"          # unknown rc / timeout / silence: assume the bytes may have landed


# ⛔ A pane whose NAME says "never dispatch here" is the SUPERVISOR, and dispatching to it is the
# failure AGENTS.md names (FINDING-lane-dispatched-to-orchestrator-2026-10-11). For a canary the
# problem is worse than noise: a supervisor pane that happens to be idle CONSUMES the message, the
# send returns 0, the failure is recorded as DELIVERED and suppressed forever — while the actor that
# could fix it was never told. So a name carrying any of these markers is never auto-selected.
FORBIDDEN_WS_MARKERS = ("never dispatch", "do not dispatch", "don't dispatch", "no dispatch")


def find_controller_workspace(sh, wanted_name=None):
    """Discover the controller pane's UUID from `cmux workspace list`, or None.

    Discovery is a CONVENIENCE, never an assumption: `--controller-ws` is the explicit form and is
    honoured as an operator decision. Auto-discovery refuses a NEVER-DISPATCH pane, and a discovery
    failure (cmux unreachable — e.g. from launchd, "Access denied - only processes started inside
    cmux can connect") returns None so the caller reports NOT DELIVERED instead of a fake success.
    """
    rc, out = sh.sh("cmux workspace list --id-format uuids 2>&1")
    if rc != 0 or not out.strip():
        return None, "cmux workspace list failed rc=%s: %s" % (rc, (out or "").strip()[:200])
    want = (wanted_name or "ORCHESTRATOR").upper()
    matches, refused = [], []
    for line in out.splitlines():
        line = line.lstrip("* ").rstrip()
        m = re.match(r"^(?P<uuid>[0-9A-Fa-f-]{20,})\s+(?P<name>.*?)(\s+\[.*\])?$", line)
        if not m or want not in m.group("name").upper():
            continue
        name = m.group("name").strip()
        low = name.lower()
        if any(mark in low for mark in FORBIDDEN_WS_MARKERS):
            refused.append(name)
            continue
        matches.append((m.group("uuid"), name))
    if matches:
        return matches[0][0], "matched %r" % matches[0][1]
    if refused:
        return None, ("matched %r but it is marked NEVER DISPATCH (the supervisor pane) — pass "
                      "--controller-ws explicitly if that really is the destination" % refused[0])
    return None, "no workspace whose name contains %r in cmux workspace list (%d rows)" % (
        want, len(out.splitlines()))


def send_message(msg, cfg, sh, dry_run=False, ws=None, label=None):
    """Deliver one message through scripts/safe-send.sh. Returns (delivered, detail).

    `safe-send.sh` is the sanctioned path: it refuses a lane that is busy or whose state is
    UNKNOWN (lane-guard.py), refuses a pane with no pi (a send there is EXECUTED by the shell),
    sends through cmux_dispatch.py, and reports consumption. A bare `cmux send` returns 0 on text
    merely typed — which is the defect this whole path exists to avoid.
    """
    label = label or "outcome-canary"
    if dry_run:
        return False, "DRY-RUN: not sent (would use scripts/safe-send.sh → %s)" % (ws or "<controller ws>")
    if not ws:
        return False, "NOT DELIVERED: no controller workspace resolved"
    script = _safe_send_path()
    if not script:
        return False, "NOT DELIVERED: scripts/safe-send.sh not found next to this tool"
    tmpdir = os.path.join(os.path.dirname(os.path.abspath(cfg.state_path or default_state_path())),
                          "outbox")
    try:
        os.makedirs(tmpdir, exist_ok=True)
    except Exception as exc:
        return False, "NOT DELIVERED: cannot create outbox (%s)" % exc
    path = os.path.join(tmpdir, "%s.txt" % re.sub(r"[^A-Za-z0-9_.-]", "_", label))
    try:
        with open(path, "w") as fh:
            fh.write(msg)
    except Exception as exc:
        # The makedirs above only covers a MISSING directory; an existing one can still be read-only
        # or full, and an unguarded write there kills the run AFTER the verdicts were computed — no
        # report, an exit code that mimics a FAIL, and the composed message in no artifact at all.
        return False, "NOT DELIVERED: cannot write the message to the outbox (%s: %s)" % (
            type(exc).__name__, exc)
    # ⛔ `--notice`, NOT a bare send (review cycle 5, P1). This message is a MACHINE-COMPOSED ALERT —
    # a statement about a fleet condition, with no brief and no research question — so it goes through
    # safe-send.sh's scoped notice mode. Without it the research-first gate (#2258) refused every alert
    # with 80, and because an unknown rc classified as AMBIGUOUS it was then suppressed on every later
    # poll: the controller was never told, and the report said "bytes may have landed" about a message
    # that was provably never sent. The no-pi and busy guards still apply under --notice.
    rc, out = sh.sh("bash %s %s %s %s --notice" % (_q(script), _q(ws), _q(label), _q(path)), timeout=300)
    verdict = classify_send(rc, out)
    if verdict == "delivered":
        detail = SAFE_SEND_RC[0]
    elif verdict == "refused":
        detail = "REFUSED: rc=%s %s" % (rc, out.strip()[:300])
    else:
        detail = "AMBIGUOUS: rc=%s %s" % (rc, (out.strip() or "no output")[:300])
    if verdict != "delivered":
        # A send that did not land must leave a DURABLE artifact: an alert that can never be
        # delivered is an inert one. The composed message is on disk and its path is in the report.
        detail += " (message kept at %s)" % path
    return verdict == "delivered", detail


def _q(s):
    return "'" + str(s).replace("'", "'\\''") + "'"


def capture_message(msg, capture_dir, v):
    """Write the message to a file instead of sending it. Same delivery REPORT, no side effect.

    This exists so the suite can assert what the canary would say without a controller in the loop,
    and so an operator can read the exact message before pointing the canary at a real pane.
    """
    try:
        os.makedirs(capture_dir, exist_ok=True)
        path = os.path.join(capture_dir, "%s--%s--%s.txt"
                            % (int(time.time()), v.name, v.variant))
        with open(path, "w") as fh:
            fh.write(msg)
        return True, "CAPTURED to %s (not sent)" % path
    except Exception as exc:
        return False, "NOT DELIVERED: capture failed (%s)" % exc


def _safe_send_path():
    here = os.path.dirname(os.path.abspath(__file__))
    for cand in (os.path.join(here, "..", "..", "scripts", "safe-send.sh"),
                 os.path.expanduser("~/.pi/agent/scripts/safe-send.sh")):
        if os.path.exists(cand):
            return os.path.normpath(cand)
    return None


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Respawn — ONLY when the controller is genuinely absent
# ════════════════════════════════════════════════════════════════════════════════════════════════

RESPAWN_TRIGGERS = ("CONTROLLER_ABSENT", "LAUNCHD_PID_UNRESOLVED")

# ⛔ The launchd forms this file must NEVER use are `unload -w` and `load -w`: `-w` writes a
# PERSISTENT Disabled override (man launchctl), so an unload/load pair whose bootstrap fails leaves
# the controller removed AND disabled, silently — measured 2026-10-17, 48 minutes of dead dispatch
# then 19 more (agent-infra#1975). They are named in PROSE on purpose and not as string constants:
# the suite asserts that no quoted forbidden token appears anywhere in this file, and a constant
# holding one would be indistinguishable from a real use. The in-place restart is `kickstart -k`;
# a service that is not loaded at all is `bootstrap`.


def respawn_plan(label, uid, plist):
    """The argv list, in order. kickstart restarts IN PLACE (no plist rewrite, no override);
    bootstrap is the fallback for a service that is not loaded at all."""
    return [
        ["launchctl", "kickstart", "-k", "gui/%s/%s" % (uid, label)],
        ["launchctl", "bootstrap", "gui/%s" % uid, plist],
    ]


def attempt_respawn(v, cfg, machine, dry_run=False, plist=None, uid=None, poll_deadline_s=None):
    """Respawn an ABSENT controller, then PROVE whether it took.

    Returns a dict: {"attempted", "commands":[(argv, rc, out)], "took", "detail"}. `took` requires
    POSITIVE evidence — a controller process AND an advancing log/heartbeat — never the exit code of
    `launchctl` alone, which says the request was accepted, not that the controller runs.
    """
    res = {"attempted": False, "commands": [], "took": False, "detail": ""}
    if variant_of(v) not in RESPAWN_TRIGGERS:
        res["detail"] = "not attempted: the controller is not absent (%s)" % variant_of(v)
        return res
    # ⛔ A SCOPE THAT DOES NOT HOLD THE CONTROLLER'S SCRIPT CANNOT ESTABLISH ABSENCE. The census is
    # path-scoped, so `--o /tmp/typo` (or any cell whose `$O` is not the default, armed without
    # `--o`) REJECTS the running controller as "another cell's" — `pids: []`, `near_miss: False` —
    # and `launchctl kickstart -k` fires at a live controller mid-cycle. The scoped VERDICT is right
    # (this cell's controller cannot be found under that scope); the ACTION is not, because nothing
    # was established about the controller that actually runs. Measured on the live box: the evidence
    # block printed the live pid as "not this cell's controller" while the trigger was
    # LAUNCHD_PID_UNRESOLVED — a member of RESPAWN_TRIGGERS.
    scope_paths = [x for x in cfg.controller_paths() if x]
    if scope_paths:
        usable, unprobed = [], []
        for cand in scope_paths:
            rc_e, out_e = machine.sh("test -e %s && echo YES || echo NO" % _q(cand))
            if rc_e != 0:
                unprobed.append((cand, (out_e or "").strip()[:120]))
                continue
            usable.append((out_e or "").strip().endswith("YES"))
        if unprobed and not any(usable):
            # ⛔ A FAILED PROBE IS NOT A MISSING SCRIPT. `rc != 0` (a `cmux cloud exec` that could not
            # connect, a timeout at load 115) says the scope was never READ — reporting "the scope
            # does not contain the controller's script" from it is a claim about the world built from
            # a read that did not happen, and it points the operator at a path that may be fine. The
            # action is refused either way; only the SENTENCE changes.
            res["attempted"] = False
            res["detail"] = ("NOT ATTEMPTED: the scope could not be PROBED (%s) — so nothing is "
                             "established about where the controller runs, and absence cannot be "
                             "claimed" % "; ".join("%s: %s" % (c, e or "no output")
                                                   for c, e in unprobed[:3]))
            res["scope_unusable"] = True
            res["scope_unreadable"] = True
            return res
        if not any(usable):
            res["attempted"] = False
            res["detail"] = ("NOT ATTEMPTED: the scope does not contain the controller's script "
                             "(%s) — nothing was established about the controller that IS running, "
                             "so absence cannot be claimed and no job may be restarted"
                             % ", ".join(scope_paths[:3]))
            res["scope_unusable"] = True
            return res
    if dry_run:
        res["attempted"] = False
        res["detail"] = "DRY-RUN: would run `%s`%s" % (
            " ".join(respawn_plan(cfg.label, uid or "$UID", plist or "$PLIST")[0]),
            " (no controller process found)")
        res["commands"] = [(respawn_plan(cfg.label, uid or "$UID", plist or "$PLIST")[0], None, "dry-run")]
        return res
    if getattr(machine, "remote", False):
        res["detail"] = ("NOT ATTEMPTED: the controller is on a REMOTE machine (%s) and this "
                         "version only respawns a launchd job on the local box. This is a stated "
                         "gap, not a silent skip." % getattr(machine, "box", "?"))
        return res

    res["attempted"] = True
    before = _controller_fingerprint(machine, cfg)
    # RE-MEASURE AT THE MOMENT OF ACTION. The ABSENT verdict comes from facts collected earlier
    # (log stat + tail, heartbeat, ps, launchctl, per-pid reads, df, vm_stat, two gh calls with
    # 120s timeouts each). With launchd's KeepAlive, a controller can come back inside that window,
    # and `kickstart -k` would then KILL A LIVE CONTROLLER MID-CYCLE — the one action this file says
    # must never happen. The fresh reading is already in hand: read it, and abstain if it is alive.
    if before.get("ok") is False:
        res["attempted"] = False
        res["detail"] = ("NOT ATTEMPTED: the process table could not be read at the moment of "
                         "action, so a live controller cannot be ruled out — an unreadable read is "
                         "NOT absence (%s)" % (before.get("error") or "no error recorded"))
        return res
    if before.get("near_miss"):
        res["attempted"] = False
        res["detail"] = ("NOT ATTEMPTED: the re-measure REJECTED a process whose command names this "
                         "cell's orch-loop.sh — the scoped census cannot resolve it, so a live "
                         "controller cannot be ruled out")
        return res
    if before.get("pids_ok") is not True:
        res["attempted"] = False
        res["detail"] = ("NOT ATTEMPTED: the re-measure returned no `pids` LIST (ok=%r), so a live "
                         "controller cannot be ruled out — an absent process list is not absence"
                         % (before.get("ok"),))
        return res
    if before.get("pids"):
        res["attempted"] = False
        res["detail"] = ("NOT ATTEMPTED: a controller appeared after the facts were collected "
                         "(pid(s) %s, log %s) — not touching a live controller"
                         % (", ".join(str(p) for p in before["pids"]),
                            _age_txt(before.get("log_age_s"))))
        return res
    last_out = ""
    for argv in respawn_plan(cfg.label, uid or _uid(), plist or _plist_path(cfg.label)):
        rc, out = machine.sh_argv(argv)
        res["commands"].append((argv, rc, out.strip()[:300]))
        last_out = out.strip()[:300]
        if rc == 0:
            break
    # PROVE it: poll for a controller process AND an advancing log.
    deadline = time.time() + (poll_deadline_s if poll_deadline_s is not None else cfg.respawn_timeout_s)
    while time.time() < deadline:
        time.sleep(2)
        after = _controller_fingerprint(machine, cfg)
        # POSITIVE evidence only: a live controller process AND the log ADVANCED across this attempt.
        # A `launchctl` rc=0 proves the REQUEST was accepted, not that a controller runs (the
        # 2026-10-17 outage had a successful rc and no controller), and an absolute "log is recent"
        # bound is satisfied by a log written before the attempt.
        # POSITIVE evidence that a controller STARTED, from either clock it publishes — the log
        # (written last: rate_limit, reap, load, header) or the heartbeat (written first). Both are
        # ADVANCES across this attempt, never an absolute "it is recent" bound, which a pre-existing
        # log would satisfy.
        log_advanced = (after.get("mtime") is not None and
                        (before.get("mtime") is None or after["mtime"] > before["mtime"]))
        hb_advanced = (after.get("hb") is not None and
                       (before.get("hb") is None or after["hb"] > before["hb"]))
        advanced = log_advanced or hb_advanced
        if after.get("pids") and advanced:
            res["took"] = True
            res["detail"] = ("RESPAWN TOOK: pid(s) %s appeared and the log advanced (%s)"
                             % (", ".join(str(p) for p in after["pids"]),
                                _age_txt(after.get("log_age_s"))))
            return res
    res["detail"] = ("RESPAWN DID NOT TAKE within %.0fs — before: %s; after: %s; last launchctl output: %s"
                     % (poll_deadline_s or cfg.respawn_timeout_s, before, _controller_fingerprint(machine, cfg),
                        last_out or "(none)"))
    return res


def _send_rc_is_ambiguous(detail):
    """Was the last attempt AMBIGUOUS (bytes may be in the composer) rather than REFUSED (nothing
    consumed)? The detail is rendered by `send_message` FROM `classify_send`, so the report and the
    suppression rule read one classifier — never a second mapping that can drift."""
    return (detail or "").startswith("AMBIGUOUS")


def variant_of(v):
    if isinstance(v, Verdict):
        return v.variant
    if isinstance(v, dict):
        return v.get("variant")
    return getattr(v, "variant", None)


def _controller_fingerprint(machine, cfg):
    """{ok, pids, mtime, log_age_s} — `ok` and `mtime` are here because BOTH are load-bearing:

    * `ok` — an unreadable process table (`ps` timing out at load 130) yields `pids: []`, which reads
      exactly like ABSENCE. Dropping the flag here re-opened the very defect the collector closed, in
      the ACTION path, where the cost is `kickstart -k` against a live controller.
    * `mtime` — "the log advanced" must mean the log ADVANCED across the attempt, not "the log is
      recent". A log written 30s before a failed respawn satisfies any absolute age bound.
    """
    snap = machine.snapshot_controller() or {}
    log = machine.log_stat() or {}
    # ⛔ ALLOW-LIST POLARITY IN THE ACTION PATH. `snap.get("ok", True)` defaults an ABSENT read to a
    # successful one, so the RE-MEASURE AT THE MOMENT OF ACTION degraded to "empty table = absence"
    # and `launchctl kickstart -k` ran against a live controller. `is True` makes an absent/None `ok`
    # abstain exactly like every other read in this file.
    # `pids_ok` carries WHICH read produced the list: `attempt_respawn` refuses on it, so an absent
    # process list at the moment of action cannot present as "nothing is running".
    _paths = [p for p in (snap.get("scoped_to") or cfg.controller_paths()) if p]
    near = _names_our_program(snap.get("near_misses") or [], paths=_paths,
                              names=() if _paths else ("orch-loop.sh",))
    return {"ok": snap.get("ok") is True,
            # ⛔ THE ERROR IS CARRIED, NOT DISCARDED. `attempt_respawn` prints `before["error"]` as
            # the reason it refused, and this dict never had the key — so the one channel that
            # explains the refusal said "(no error recorded)" while the `ps` failure text it had
            # just read was thrown away.
            "error": snap.get("error"),
            "pids_ok": isinstance(snap.get("pids"), list),
            # ⛔ THE CENSUS IS SCOPED, SO ITS EMPTY `pids` DOES NOT PROVE ABSENCE. A row the scope
            # REJECTED while naming this cell's controller is a live controller the census could not
            # resolve, and `kickstart -k` on it kills a cycle in flight.
            "near_miss": bool(near),
            "pids": [p.get("pid") for p in snap.get("pids") or []
                     if isinstance(p, dict)] if isinstance(snap.get("pids"), list) else [],
            "mtime": log.get("mtime"),
            "exists": log.get("exists"),
            "log_age_s": log.get("age_s"),
            "hb": _heartbeat_epoch(machine)}


def _heartbeat_epoch(machine):
    """The controller's heartbeat epoch, or None. It is written FIRST (before the loop's rate-limit
    call and its first log line), so it is the earliest positive evidence that a controller STARTED."""
    path = os.path.join(getattr(machine, "o_dir", "") or "", "heartbeat")
    if not path or not getattr(machine, "o_dir", None):
        return None
    try:
        raw, _err = machine.read_file(path)
    except Exception:
        return None
    txt = (raw or "").strip().split()[0] if (raw or "").strip() else ""
    return int(txt) if re.match(r"^\d+$", txt) else None


def _uid():
    try:
        return str(os.getuid())
    except Exception:
        return "501"


def _plist_path(label):
    return os.path.join(os.path.expanduser("~"), "Library", "LaunchAgents", "%s.plist" % label)


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Collectors — a machine (or a box reached over cmux cloud exec) → facts
# ════════════════════════════════════════════════════════════════════════════════════════════════


def _normalize_box(name):
    """The ONE spelling of a box name: this box is always `local`, a remote box is its stripped name.

    ⛔ `_is_local_box` fixed the PROBES and the repo, and left `cfg.box` unnormalised — and `cfg.box`
    is the NOTIFICATION IDENTITY (`State.data["boxes"][box]`, keyed per box). So `--box local`,
    `--box "local "` and `--box localhost` were three identities for one machine: the same failure
    was notified three times, three `box=` labels were printed, and the worst case is silent —
    fail under `local `, recover under `local` (which clears only `boxes["local"]`), fail again under
    `local `, and the key is still there, so the alert is suppressed forever.
    """
    if name is None or not str(name).strip():
        return "local"
    return "local" if _is_local_box(name) else str(name).strip()


def _post_respawn_provenance(cfg, injected_path, now=None):
    """The provenance of a report whose verdicts were RE-READ LIVE after a respawn.

    ⛔ THE PROVENANCE MUST FOLLOW THE VERDICTS. `header`, `obs_iso` and the injected flag were built
    from the payload before the action and never recomputed, so a `--facts` run whose respawn took
    printed "FACTS INJECTED (…; not a live observation)" over LIVE verdicts and emitted
    `facts_injected: true` beside a live `observed_at` — the two fields a consumer uses to judge
    currency, contradicting `facts_source` in the same payload.
    """
    when = now if now is not None else time.time()
    obs_iso = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(when))
    return {
        "injected": False,          # these verdicts came from a live read, whatever fed the first
        "observed_at": obs_iso,
        "header": ("outcome canary — %s box=%s repo=%s  %s\n"
                   "window=%.0fs  pr-window=%.0fs  mem-floor=%.0fMiB  disk-floor=%.0fGiB  "
                   "pool-threshold=%d"
                   % ("LIVE (re-collected after the respawn)", cfg.box,
                      cfg.repo or "(unknown — pass --repo)", obs_iso, cfg.window_s,
                      cfg.pr_window_s, cfg.mem_floor_mb, cfg.disk_floor_gb, cfg.pool_threshold)),
        "facts": (("injected for the first read (%s); RE-COLLECTED LIVE after the respawn"
                   % injected_path) if injected_path else "live collection"),
    }


def _is_local_box(name):
    """Is this box name THIS machine? `local`, `localhost` and `.` are, whitespace and all.

    ⛔ ONE DEFINITION, TWO CALLERS. `cfg_from_args` stripped the name and `Machine` did not, so
    `--box "local "` read as remote: every probe went through `cmux cloud exec "local "` (rc 127,
    the whole report INCONCLUSIVE) while the three PR checks read THIS box's repo — and the send and
    respawn refusals then told the operator "box local  is REMOTE", a false statement about the
    machine they are sitting at.
    """
    return (name or "local").strip().lower() in ("local", "localhost", ".")


class Machine(object):
    """Command boundary. Local = a bash subshell; remote = `cmux cloud exec <box> -- sh -c …`.

    Every probe is a POSIX shell command so ONE implementation serves both, and `--box` cannot
    drift into a second set of predicates. `remote` is recorded so the respawn path can refuse
    honestly instead of pretending to restart a job it cannot reach, and so the SEND path can use
    a LOCAL runner: `cmux workspace list`/`safe-send.sh` must run where the cmux socket is.
    """

    MAX_TIMEOUT = 900

    def __init__(self, box=None, timeout=120):
        self.box = _normalize_box(box)
        self.remote = not _is_local_box(self.box)
        self.timeout = timeout
        self.log_path = None
        self.tail_lines = 6000
        # The cell's own controller script(s). Scoping the census to them is the supervisor's rule
        # (`scripts/cloud-cell-supervisor.sh`), and it is what makes "a controller exists" a claim
        # about THIS cell instead of a claim about the box.
        self.controller_paths = None
        self.o_dir = None

    def local(self):
        """A runner for LOCAL-only work (cmux discovery, the sanctioned send)."""
        m = Machine(None, timeout=self.timeout)
        m.log_path = self.log_path
        m.tail_lines = self.tail_lines
        m.controller_paths = self.controller_paths
        m.o_dir = self.o_dir
        return m

    def sh(self, cmd, timeout=None):
        t = timeout if timeout is not None else self.timeout
        if self.remote:
            argv = ["cmux", "cloud", "exec", "--timeout", str(self._clamp(t)),
                    self.box, "--", "sh", "-c", cmd]
        else:
            argv = ["/bin/bash", "-lc", cmd]
        return self._run(argv, t)

    def sh_argv(self, argv, timeout=None):
        """Run an ARGV, honouring the remote boundary exactly once."""
        t = timeout if timeout is not None else self.timeout
        argv = list(argv)
        if self.remote:
            argv = ["cmux", "cloud", "exec", "--timeout", str(self._clamp(t)),
                    self.box, "--"] + argv
        return self._run(argv, t)

    def _clamp(self, t):
        try:
            return max(1, min(int(t), self.MAX_TIMEOUT))
        except Exception:
            return 30

    def _run(self, argv, t):
        try:
            p = subprocess.run(argv, capture_output=True, text=True, timeout=t)
            out = p.stdout or ""
            if p.returncode != 0 and p.stderr:
                out = out + "\n" + p.stderr
            return p.returncode, out
        except Exception as exc:
            return 127, "%s: %s" % (type(exc).__name__, exc)

    # ── individual probes ────────────────────────────────────────────────────────────────────
    def snapshot_controller(self):
        """{"ok", "pids", "error"}. `ok: False` is an ABSTENTION, never emptiness.

        ⛔ An unreadable process table used to return `pids: []`, which `check_controller_cycling`
        read as "no controller" — the ONE state that triggers a respawn. A `ps` that times out on a
        box at load 130 would then `launchctl kickstart -k` a controller that is running fine
        (measured fleet behaviour: a single cmux call takes 13-15s at that load).
        """
        rc, out = self.sh("ps -Ao pid=,ppid=,command= 2>&1")
        # ⛔ EMPTY STDOUT IS A FAILED READ — the doctrine `_json_list` states for gh, which `ps`
        # never received. `ps -Ao` prints at least one row on any live system, so empty-with-rc0
        # is a broken probe. Reading it as "no such process" reached CONTROLLER_ABSENT — the only
        # state that RESPAWNS — and the re-measure guard uses the same probe and the same polarity,
        # so it could not save it.
        if rc != 0 or not (out or "").strip():
            return {"ok": False, "pids": [],
                    "error": ((out or "").strip()[:300] or "empty process table (rc=0)")}
        rows, near = pick_controller_pids(out, self.controller_paths)
        return {"ok": True, "pids": rows, "near_misses": near[:8],
                "scoped_to": list(self.controller_paths or [])}

    def snapshot_pane(self):
        rc, out = self.sh("ps -Ao pid=,command= 2>&1")
        if rc != 0 or not out.strip():
            return {"ok": False, "pids": [],
                    "error": (out.strip()[:300] or "empty process table (rc=0)")}
        rows, near = pick_pane_daemon_pids(out)
        pids = [{"pid": r["pid"], "oom_score_adj": self.oom_score_adj(r["pid"])} for r in rows]
        probe_rc, probe = self.sh("test -r /proc/self/oom_score_adj && echo yes || echo no")
        supported = (probe.strip().endswith("yes"))
        rec = {"ok": True, "pids": pids, "cmd": "cmux-tui",
               "near_misses": near[:8],
               "protection_supported": supported,
               "protection_source": "oom_score_adj" if supported else None}
        if not supported:
            rec["protection_note"] = ("no /proc/<pid>/oom_score_adj on this platform"
                                      if self.remote or not os.path.isdir("/proc")
                                      else "kernel does not expose oom_score_adj")
        return rec

    def oom_score_adj(self, pid):
        rc, out = self.sh("cat /proc/%s/oom_score_adj 2>/dev/null" % pid)
        if rc != 0:
            return None
        out = out.strip()
        return int(out) if re.match(r"^-?\d+$", out) else None

    def stat_mtime(self, path):
        """mtime of `path`, or None when it cannot be read. A failed read is not a mtime."""
        rc, out = self.sh("stat -c %%Y %s 2>/dev/null || stat -f %%m %s 2>/dev/null"
                          % (_q(path), _q(path)))
        return parse_stat_mtime(out) if rc == 0 else None

    def log_stat(self):
        """{exists, mtime, mtime_iso, age_s, error} — stat only, NO tail.

        The respawn poll runs every 2s; reading a 6000-line tail each time would make the canary a
        load source on the box it is measuring. `exists` distinguishes MISSING from UNREADABLE here
        exactly as `read_log` does.
        """
        rc, out = self.sh("stat -c %%Y %s 2>/dev/null || stat -f %%m %s 2>/dev/null"
                          % (_q(self.log_path), _q(self.log_path)))
        mtime = parse_stat_mtime(out) if rc == 0 else None
        rec = {"path": self.log_path, "mtime": mtime, "age_s": None,
               "error": (out or "").strip()[-200:] or None}
        if mtime is not None:
            rec["exists"] = True
            # ⛔ A future mtime is UNKNOWN, not 0s-old. `max(0, ...)` turned a clock-skewed cell into
            # the freshest possible log, so the "pid alive but the log stopped" state — the one that
            # must fire — read PASS, and since absence is the only respawn trigger nothing was raised.
            skew = time.time() - mtime
            rec["age_s"] = (None if skew < -CLOCK_SKEW_TOLERANCE_S else max(0.0, skew))
            if rec["age_s"] is None:
                rec["error"] = "log mtime is %.0fs in the FUTURE (clock skew)" % (-skew)
            rec["mtime_iso"] = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(mtime))
            return rec
        rc3, present = self.sh("test -e %s && echo YES || echo NO" % _q(self.log_path))
        rec["exists"] = (present.strip().endswith("YES")) if rc3 == 0 else None
        return rec

    def facts_probe_log(self):
        """(log record, tail lines). The log IS the outcome ledger, so its tail is read once."""
        log, lines, _err = self.read_log(self.log_path)
        return log, lines

    def read_log(self, path):
        """(log record, tail lines, error). One stat, one tail.

        ⛔ GNU `stat -f %m FILE` does NOT fail: on Linux it prints a six-line FILESYSTEM block whose
        last line happens to be the epoch. Reading `stat -f` first therefore looked like success,
        `isdigit()` on the whole block was false, and every Linux box reported the log as MISSING —
        which fails `controller_cycling` with LOG_MISSING and blinds both log checks. GNU `-c` is
        tried first (it fails loudly on BSD), and the answer is read from the LAST line, which is
        correct for both shapes.
        """
        rc, out = self.sh("stat -c %%Y %s 2>/dev/null || stat -f %%m %s 2>/dev/null"
                          % (_q(path), _q(path)))
        rc2, tail = self.sh("tail -n %d %s 2>&1" % (self.tail_lines, _q(path)))
        mtime = parse_stat_mtime(out) if rc == 0 else None
        if mtime is None:
            # ⛔ MISSING and UNREADABLE are different states, and conflating them grades a TCC/EACCES
            # denial (or a timed-out `cmux cloud exec`) as "the log does not exist" — a claim about
            # the world made from a failed read. `test -e` separates them.
            rc3, present = self.sh("test -e %s && echo YES || echo NO" % _q(path))
            exists = (present.strip().endswith("YES")) if rc3 == 0 else None
            return ({"path": path, "exists": exists, "age_s": None,
                     "error": (out or "").strip()[-200:] or "stat returned no epoch"}, [], "stat")
        now = time.time()
        # ⛔ A FAILED `tail` IS A MISSING READ, NOT AN EMPTY LOG. The exit status was discarded, so a
        # log whose tail could not be read (EACCES/TCC, a timed-out remote exec) came back with an
        # EMPTY line list and a fresh mtime — and `controller_cycling` graded the pair
        # FAIL/LOG_NO_CYCLE ("the log IS advancing, but not by a cycle"): a MEASURED claim about
        # content that was never read, on the check an operator reads first. `queue_readable` already
        # abstains on the same datum (NO_REFRESH) — one datum, one polar.
        tail_ok = rc2 == 0
        tail_lines = tail.splitlines() if tail_ok else []
        tail_err = None if tail_ok else ("tail failed rc=%s: %s" % (rc2, (tail or "").strip()[-160:]))
        skew = now - mtime
        return ({"path": path, "exists": True, "mtime": mtime,
                 "mtime_iso": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(mtime)),
                 # same rule as the events: a future mtime is UNKNOWN, never the freshest possible
                 "age_s": (None if skew < -CLOCK_SKEW_TOLERANCE_S else max(0.0, skew)),
                 "tail_ok": tail_ok, "tail_error": tail_err,
                 "error": ("log mtime is %.0fs in the FUTURE (clock skew)" % (-skew)
                           if skew < -CLOCK_SKEW_TOLERANCE_S else None)}, tail_lines, None)

    def read_file(self, path):
        rc, out = self.sh("cat %s 2>&1" % _q(path))
        if rc != 0:
            return None, out.strip()[:200]
        return out, None

    def launchd_state(self, label):
        rc, out = self.sh("launchctl list 2>&1")
        if rc != 0 or not (out or "").strip():
            return {"loaded": None, "pid": None, "label": label,
                    "error": ((out or "").strip()[:200] or "empty launchctl list (rc=0)")}
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) >= 3 and parts[2].strip() == label:
                pid = parts[0].strip()
                return {"loaded": True, "pid": int(pid) if pid.isdigit() else None, "label": label}
        return {"loaded": False, "pid": None, "label": label}

    def headroom(self, path):
        rc, out = self.sh("df -k %s 2>&1 | tail -1" % _q(path))
        disk = {"ok": False, "error": (out or "").strip()[:200]}
        if rc == 0 and out.strip():
            f = out.split()
            # POSIX df -k: Filesystem 1024-blocks Used Available Capacity Mounted-on
            if len(f) >= 5 and f[3].isdigit():
                cap = f[4].rstrip("%")
                disk = {"ok": True, "avail_bytes": int(f[3]) * 1024,
                        "used_pct": float(cap) if cap.isdigit() else None,
                        "mount": f[-1]}
        rc, out = self.sh(
            "if [ -r /proc/meminfo ]; then awk '/^MemAvailable:/{print \"linux \" $2}' /proc/meminfo; "
            "else vm_stat | awk '/page size of/{ps=$8; seen=1} /Pages free/{free=$3} "
            "/Pages inactive/{inact=$3} /Pages speculative/{spec=$3} "
            # ⛔ UNSEEN FIELDS MUST NOT PRINT A NUMBER. The END block used to emit
            # `(free+inact+spec)*ps` unconditionally, so a `vm_stat` whose wording moved (or which
            # failed) yielded `%d` of the uninitialised/zero fields = `darwin 0` — and `0 MiB` is a
            # FAIL/BELOW_FLOOR, i.e. an UNREADABLE probe reported as an OOM emergency on the one
            # check whose FAIL is supposed to mean one. `seen` makes the read's own success explicit.
            "END{gsub(/\\./,\"\",ps); gsub(/\\./,\"\",free); gsub(/\\./,\"\",inact); "
            "gsub(/\\./,\"\",spec); "
            # inact/spec are SUMMED, so a reworded label for either silently contributed 0: measured
            # on this box, rewording "Pages inactive"/"Pages speculative" turned 7.0 GiB into 214 MiB
            # and produced FAIL/BELOW_FLOOR on a healthy machine.
            "if (!seen || ps == \"\" || free == \"\" || inact == \"\" || spec == \"\") "
            "print \"darwin UNKNOWN\"; "
            "else printf \"darwin %d\\n\", (free+inact+spec)*ps/1024/1024}'; fi 2>&1")
        mem = {"ok": False, "error": (out or "").strip()[:200]}
        if rc == 0 and out.strip():
            parts = out.split()
            if len(parts) >= 2:
                try:
                    kb = float(parts[1])
                    mb = kb / 1024.0 if parts[0] == "linux" else kb
                    mem = {"ok": True, "avail_mb": mb, "source": parts[0]}
                except ValueError:
                    pass
        return {"disk": disk, "mem": mem}


def pick_controller_pids(ps_out, controller_paths=None):
    """Every process that IS this cell's controller: argv is EXACTLY `<shell> <path>`.

    ⛔ THREE ARTIFACTS ARE NAMED HERE, all measured, all the same root — an UNSCOPED match:
    1. "6 controllers for 3 cells" (2026-10-15): a substring search counted jobs that are not
       controllers. `scripts/cloud-cell-supervisor.sh:277-300` fixed the same bug in the supervisor
       by scoping the match to `$O/orch-loop.sh`/`$HARNESS/orch-loop.sh` and excluding descendants.
    2. A `bash -c '<string>'` invocation whose TEXT ends in the script path (a leftover
       `bash -c tail -f /dev/null; : …/O/orch-loop.sh`) matched a tail-anchored regex, so a DEAD
       fleet read as cycling and the ABSENT state that owns the respawn was never reached.
    3. Measured 2026-10-18: two leaked test-fixture processes
       (`…/T/fleet-inventory-test.*/O/orch-loop.sh`) satisfied "a controller exists", so the census
       read 3 controllers for 1 real one — a false PASS on `controller_cycling` AND a respawn that
       refused to act ("a controller appeared") because the only live pids were stubs.
    The controller takes NO arguments (`<shell> <path>`), so the whole argv after the shell must BE
    the expected path. That is the supervisor's rule; this is a CONSUMER of it, not a second verdict,
    and `controller_paths` is derived from the same `$O` every other probe uses. Near-misses are
    returned separately as evidence — a reader must be able to see what was rejected and why, or
    "no controller" looks like "there was nothing to see".
    """
    rows, near = [], []
    paths = [os.path.normpath(p) for p in (controller_paths or []) if p]
    for line in ps_out.splitlines():
        line = line.strip()
        if "orch-loop.sh" not in line:
            continue
        parts = line.split(None, 2)
        if len(parts) < 3 or not parts[0].isdigit():
            continue
        pid = int(parts[0])
        ppid = int(parts[1]) if parts[1].isdigit() else None
        cmd = parts[2]
        toks = cmd.split()
        if not toks:
            continue
        row = {"pid": pid, "ppid": ppid, "cmd": cmd[:300]}
        # THREE conjuncts, and each is load-bearing on its own (a fourth — `len(toks) == 2` — was
        # tried and removed: with the tail anchor and the path check in place it could never be the
        # reason for a verdict, i.e. it was dead code in a gate):
        #   1. argv[0] is a SHELL. `/usr/bin/env bash <path>` is a real way to start something that
        #      is not the controller, and so is any non-shell interpreter holding the path.
        #   2. the command ENDS with `orch-loop.sh`, which excludes a `-c` string that merely
        #      mentions the script anywhere but at the end.
        #   3. the ONE token after the shell is THIS CELL's controller path. That excludes another
        #      cell's controller and every leaked fixture (`…/T/fleet-inventory-test.*/O/orch-loop.sh`),
        #      and it rejects the `-c`/`-lc` string forms too, because their second token is an
        #      option and not the path.
        if not re.match(r"^(\S*/)?(ba|z|da|k)?sh$", toks[0]):
            near.append(row)
            continue
        if not re.search(r"(^|\s)(\S*/)?orch-loop\.sh$", cmd):
            near.append(row)
            continue
        if paths and os.path.normpath(toks[1]) not in paths:
            near.append(row)          # a DIFFERENT cell's controller, or a fixture: not ours
            continue
        rows.append(row)
    by_pid = dict((r["pid"], r) for r in rows)
    for r in rows:
        depth, seen, cur = 0, set(), r
        while cur and cur["ppid"] in by_pid and cur["pid"] not in seen:
            seen.add(cur["pid"])
            cur = by_pid.get(cur["ppid"])
            depth += 1
        r["depth"] = depth
    rows.sort(key=lambda r: (-r["depth"], -r["pid"]))
    return rows, near


# ── gh: read-only, through the REAL binary ──────────────────────────────────────────────────────

GH_CANDIDATES = ("/Users/danielospina/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh",
                 "/usr/bin/gh")


def resolve_gh():
    """The real binary, resolved ABSOLUTELY.

    `gh` on PATH resolves to the agent gh-shim, which refuses harness-looking calls (measured while
    building this: every `gh pr list` from the agent shell was refused with the review-gate text).
    The harness's read-only callers resolve the binary directly for the same reason.
    """
    env = os.environ.get("OUTCOME_CANARY_GH")
    if env and os.path.exists(env):
        return env
    for p in GH_CANDIDATES:
        if os.path.exists(p):
            return p
    return None


def _gh_empty():
    return {"ok": False, "error": None, "source": None,
            "prs_created_in_window": None, "prs_merged_in_window": None,
            "open_pr_count": None, "open_prs": [], "last_created": None, "last_merged": None}


def collect_github(repo, cfg, now=None):
    """PR populations for checks 4/5/8. Any failure → ok=False, never an empty list that reads 0.

    TWO SURFACES, and the one that answered is part of the EVIDENCE. GraphQL answers the whole
    question in one call (rollup + autoMergeRequest), so it is tried first — but gh's GraphQL bucket
    is shared with every other lane on the box and is routinely EXHAUSTED while REST still has
    thousands of calls left (the harness grew a `gh-rest` adapter for exactly this, #1988). Reading
    "GraphQL refused" as "the PR population is unknown" would blind the three hardest checks on the
    busiest box, so REST is tried and NAMED. This is not a silent fallback: the evidence says which
    surface answered, and when neither answers the checks go INCONCLUSIVE.
    """
    now = now if now is not None else time.time()
    gh = resolve_gh()
    if not gh:
        out = _gh_empty()
        out["error"] = "no gh binary found (checked %s; set OUTCOME_CANARY_GH)" % (GH_CANDIDATES,)
        return out
    if not repo:
        out = _gh_empty()
        out["error"] = "no --repo owner/name given, so the PR population is unknown"
        return out
    errors = []
    got = _collect_graphql(gh, repo, cfg, now, errors)
    if got:
        return got
    got = _collect_rest(gh, repo, cfg, now, errors)
    if got:
        # The surface that answered is EVIDENCE, not an implementation detail: a reader must be
        # able to tell "GraphQL was refused and REST answered" from "GraphQL answered".
        got["fallback_reason"] = errors[0] if errors else None
        return got
    out = _gh_empty()
    out["error"] = " ; ".join(errors) or "gh returned nothing"
    return out


def _landing_bits(row, p, draft_key, armed_key):
    """Copy the draft / auto-armed bits from a gh payload — ONLY WHEN THE KEY IS PRESENT.

    ⛔ `bool(p.get("isDraft"))` and `p.get("autoMergeRequest") is not None` turn an ABSENT key into a
    DEFINITE `False`/`False` — "not a draft, definitely not armed". `check_landers` deliberately
    ABSTAINS on a non-bool draft and a non-bool `auto_armed` so a row whose bit was never read cannot
    produce `FAIL/LANDER_MISSING` ("the lander expired"), and both collectors made that abstention
    unreachable on the live path: they always emitted a bool. A field rename — the same class of
    break that produced the rollup's `app`/`workflowName` defect — would have silently manufactured
    a measured non-armed PR instead of reporting the bit as unread.
    """
    if draft_key in p:
        row["draft"] = bool(p[draft_key])
    if armed_key in p:
        row["auto_armed"] = p[armed_key] is not None
    return row


def _collect_graphql(gh, repo, cfg, now, errors):
    fields = ("number,mergeStateStatus,autoMergeRequest,isDraft,statusCheckRollup,"
              "reviewDecision,createdAt,mergedAt")
    rc, txt = _run_gh([gh, "pr", "list", "--repo", repo, "--state", "open", "--limit", "100",
                       "--json", fields])
    if rc != 0:
        errors.append("graphql: gh pr list --state open rc=%s: %s" % (rc, _one_line(txt)))
        return None
    open_prs = _json_list(txt)
    if open_prs is None:
        errors.append("graphql: gh pr list --state open returned unparseable JSON")
        return None
    # ⛔ THE MERGED SUBSET WAS THE WHOLE POPULATION, so a PR opened and CLOSED UNMERGED was invisible
    # and `pr_created` could report FAIL/NO_PR_CREATED for a fleet that did open it (the REST path had
    # the same hole; `also_created` closes both). `--state closed` returns merged AND closed-unmerged
    # rows in ONE call — same call count, strictly more data — and the merged subset is filtered here,
    # exactly as `_collect_rest` already did.
    rc, txt = _run_gh([gh, "pr", "list", "--repo", repo, "--state", "closed", "--limit", "100",
                       "--json", "number,mergedAt,createdAt"])
    if rc != 0:
        errors.append("graphql: gh pr list --state closed rc=%s: %s" % (rc, _one_line(txt)))
        return None
    closed = _json_list(txt)
    if closed is None:
        errors.append("graphql: gh pr list --state closed returned unparseable JSON")
        return None
    merged = [p for p in closed if p.get("mergedAt")]
    # ⛔ A CREATION-ORDERED PAGE CANNOT ANSWER "DID ANYTHING MERGE IN THE WINDOW". `pr list` is
    # creation-desc, so on any repo with ≥100 closed PRs the page is ALWAYS full and a merge older
    # than the page cut is invisible — which made `merged_page_full` true on every live run and
    # deleted `pr_merged`'s only FAIL arm on the primary surface (measured: 100 closed rows on this
    # repo, so "everything is up and nothing ships" could never be reported for merges, only
    # abstained). One MERGE-ORDERED read answers it exactly: `merged:>=<date>` returns the merges in
    # the window, so an EMPTY result genuinely establishes "nothing merged" and a non-empty one is
    # the count. The closed page stays for the created population.
    # `utcfromtimestamp` is DEPRECATED and scheduled for removal; under 3.12 (what CI runs) the
    # warning is one `-W error` away from a traceback inside `collect_live`, which exits 1 — the code
    # the docs define as "a real FAIL". The date is floored to a DAY, which can only move the bound
    # EARLIER, and `_fill_counts` re-filters with the exact window, so the query is a superset.
    since = datetime.datetime.fromtimestamp(
        now - cfg.pr_window_s, datetime.timezone.utc).strftime("%Y-%m-%d")
    rc, txt = _run_gh([gh, "pr", "list", "--repo", repo, "--state", "merged", "--limit", "100",
                       "--search", "merged:>=%s" % since, "--json", "number,mergedAt,createdAt"])
    merged_in_window_rows = None
    if rc == 0:
        merged_in_window_rows = _json_list(txt)
    out = _gh_empty()
    out["source"] = "graphql"
    if merged_in_window_rows is not None:
        # `merged_page_full` stays False even if this page is FULL: 100 in-window merges is n > 0, so
        # the bound can hide nothing that matters (the check PASSes on a positive count and never
        # needs the population). It is the absence of merges that the flag must protect, and an
        # EMPTY result of a window-bounded query is that absence, measured.
        # ⛔ THE MERGE-ORDERED PAGE CAN BE FULL TOO. `merged:>=<day-floored date>` is bounded by the
        # DAY, not by `pr_window_s`, so a full page can hold zero in-window rows and hide the merge
        # that matters: `merged_page_full=False` hardcoded there asserted "nothing merged" off a cut
        # page. The flag costs nothing on the positive side — `pr_merged` returns PASS on `n > 0`
        # BEFORE the truncation arm — so only the `n == 0` case abstains, which is exactly the case
        # that needs it.
        _fill_counts(out, open_prs, merged_in_window_rows, cfg, now, also_created=closed,
                     merged_page_full=len(merged_in_window_rows) >= 100)
        out["merged_surface"] = "merge-ordered (merged:>=%s)" % since
    else:
        # the merge-ordered read failed: fall back to the creation-ordered page and DISCLOSE the
        # bound rather than silently under-counting
        out["fallback_note"] = ("merge-ordered read failed (rc=%s); merged count is from the "
                                "creation-ordered closed page" % rc)
        _fill_counts(out, open_prs, merged, cfg, now, also_created=closed,
                     merged_page_full=len(closed) >= 100)
    rows = []
    for p in open_prs:
        mss = (p.get("mergeStateStatus") or "").strip().upper()
        rollup = p.get("statusCheckRollup")
        # ⛔ A FULL GRAPHQL PAGE IS NOT A ROLLUP — the same doctrine `page_full` applies to the PR
        # list. `gh pr list --json statusCheckRollup` builds `contexts(first:100)` with NO
        # pagination and drops `pageInfo` (cli/cli `api/query_builder.go`), while the REST fallback
        # below DOES read `total_count`. So a PR with ≥100 contexts could have a red one beyond the
        # bound and read green here, which ADDS a lander candidate rather than dropping one.
        # Not reachable on a 54-PR repo today (max rollup length 28, measured) — but the bound is
        # the bound, and silence about it is how it becomes reachable.
        if rollup_truncated(rollup):
            green = None
            state = None
        else:
            green = rollup_is_green(rollup)
            state = rollup_state(rollup)
        rows.append(_landing_bits({
            "number": p.get("number"),
            "merge_state_status": mss,
            "checks_green": green,
            # WHICH not-green: a concluded red or an attempt still in flight. `landers` labels the
            # skip from this, so an in-flight check cannot be reported as "red".
            "checks_state": state,
            "review_decision": p.get("reviewDecision"),
            # ⛔ `probed` is NOT mergeability alone. Deriving it from `mergeStateStatus` while a
            # `None` rollup read answered "not green" put such a PR in NEITHER `candidates` NOR
            # `unprobed`: `landers` then spoke for a PR it never read, in the silencing direction.
            "probed": green is not None and mss not in MERGEABILITY_UNKNOWN,
        }, p, "isDraft", "autoMergeRequest"))
        if not rows[-1]["probed"]:
            rows[-1]["unprobed_reason"] = ("rollup truncated at its page bound"
                                           if rollup_truncated(rollup)
                                           else "no check surface read" if green is None
                                           else "mergeability unknown (%r)" % (mss,))
    out["open_prs"] = rows
    out["ok"] = True
    return out


def _collect_rest(gh, repo, cfg, now, errors):
    """REST fallback. List pages are cheap; per-PR detail + check-runs are what cost calls, so the
    probe is BOUNDED and the bound is reported. A PR beyond the bound is `probed: False`, which
    check_landers surfaces as a partial population instead of silently ignoring it."""
    rc, txt = _run_gh([gh, "api", "repos/%s/pulls?state=open&per_page=100" % repo])
    if rc != 0:
        errors.append("rest: pulls?state=open rc=%s: %s" % (rc, _one_line(txt)))
        return None
    open_raw = _json_list(txt)
    if open_raw is None:
        errors.append("rest: pulls?state=open returned unparseable JSON")
        return None
    rc, txt = _run_gh([gh, "api", "repos/%s/pulls?state=closed&per_page=100"
                       "&sort=updated&direction=desc" % repo])
    if rc != 0:
        errors.append("rest: pulls?state=closed rc=%s: %s" % (rc, _one_line(txt)))
        return None
    closed = _json_list(txt)
    if closed is None:
        errors.append("rest: pulls?state=closed returned unparseable JSON")
        return None
    merged = [p for p in closed if p.get("merged_at")]
    win_rest = cfg.pr_window_s

    out = _gh_empty()
    out["source"] = "rest"
    # updated-ordered: the page hides a merge only if it does not reach past the window
    oldest_updated = min([t for t in (parse_github_ts(p.get("updated_at")) for p in closed) if t],
                         default=None)
    page_covers_window = oldest_updated is not None and (now - oldest_updated) > win_rest
    _fill_counts(out, open_raw, merged, cfg, now, also_created=closed,
                 merged_page_full=len(closed) >= 100 and not page_covers_window)

    probe_max = int(cfg.rest_probe_max)
    rows, detail_errors = [], []
    for i, p in enumerate(open_raw):
        num = p.get("number")
        row = _landing_bits({"number": num, "merge_state_status": None, "checks_green": None,
                             "checks_state": None, "review_decision": None, "probed": False},
                            p, "draft", "auto_merge")
        # `is True`: an ABSENT draft is UNREAD, so it is neither a DRAFT skip reason nor a probe.
        if row.get("draft") is True or i >= probe_max:
            row["unprobed_reason"] = ("DRAFT" if row.get("draft") is True
                                      else "beyond rest_probe_max=%d (position %d)"
                                      % (probe_max, i + 1))
            rows.append(row)
            continue
        rc, txt = _run_gh([gh, "api", "repos/%s/pulls/%s" % (repo, num)])
        det = _json_obj(txt) if rc == 0 else None
        if det is None:
            detail_errors.append("pulls/%s rc=%s" % (num, rc))
            row["unprobed_reason"] = "pulls/%s rc=%s" % (num, rc)
            rows.append(row)
            continue
        # ⛔ NORMALISE AT THE COLLECTOR BOUNDARY, and treat "not known yet" as UNPROBED.
        # REST answers `mergeable_state: "clean"` (lowercase); comparing it to "CLEAN" dropped every
        # REST-probed PR from `candidates` while leaving `probed: True`, so it appeared in neither the
        # candidates NOR the unprobed list and `landers` said PASS/NOTHING_GREEN over zero graded PRs.
        row["merge_state_status"] = (det.get("mergeable_state") or "").strip().upper()
        sha = (det.get("head") or {}).get("sha")
        if sha:
            rc2, txt2 = _run_gh([gh, "api",
                                 "repos/%s/commits/%s/check-runs?per_page=100" % (repo, sha)])
            runs = _json_obj(txt2) if rc2 == 0 else None
            if runs is not None and isinstance(runs.get("check_runs"), list):
                row["checks_green"] = rollup_is_green(runs["check_runs"])
                total = runs.get("total_count")
                if _is_count(total) and total > len(runs["check_runs"]):
                    # ⛔ A TRUNCATED ROLLUP IS NOT A ROLLUP — the doctrine `page_full` already applies
                    # to the PR list, applied to the checks. The page holds at most 100 runs; a red
                    # run past it is invisible, so page one reading `True` became LANDERS_ARMED on a
                    # commit that is not green. `total_count` is already in hand, so it is read.
                    row["checks_green"] = None
                    detail_errors.append("commits/%s check-runs TRUNCATED (%d of %d)"
                                         % (sha[:8], len(runs["check_runs"]), total))
                row["review_decision"] = None   # REST exposes no reviewDecision; the required
                #                                  review-gate CHECK is in the rollup above, which is
                #                                  what the merge rail actually keys on.
            else:
                detail_errors.append("commits/%s/check-runs rc=%s" % (sha[:8], rc2))
        row["probed"] = (row["checks_green"] is not None
                         and row["merge_state_status"] not in MERGEABILITY_UNKNOWN)
        if not row["probed"]:
            row["unprobed_reason"] = ("no check surface read" if row["checks_green"] is None
                                      else "mergeability unknown (%r)"
                                      % (row["merge_state_status"],))
        rows.append(row)
    out["open_prs"] = rows
    # (`unprobed` was a count nothing read, and it included DRAFT rows that `landers` treats as
    # SKIPPED — a miscount waiting to be wired up. The per-row `unprobed_reason` is the disclosure.)
    if detail_errors:
        out["detail_errors"] = detail_errors[:5]
    if len(open_raw) >= 100:
        # The page bound is a POPULATION bound, not a detail: a PR beyond page one is in neither
        # `candidates` nor `unprobed`, so `landers` would speak for a population it never saw.
        out["page_full"] = True
    out["ok"] = True
    return out


def _fill_counts(out, open_prs, merged, cfg, now, also_created=None, merged_page_full=None):
    win = cfg.pr_window_s
    merged_ts = [t for t in (parse_github_ts(p.get("mergedAt") or p.get("merged_at"))
                             for p in merged) if t]
    out["prs_merged_in_window"] = len([t for t in merged_ts if now - t <= win])
    # ⛔ `gh pr list --state merged` is CREATED-desc (measured), so `--limit 100` bounds creation,
    # not merge recency: on this repo the 100 newest-created merged PRs span 7.6 days, so a PR created
    # 8+ days ago and merged in the last 3h sits OUTSIDE the page and the count reads 0 — a false
    # NO_PR_MERGED. `page_full` already discloses the same bound for open PRs; merges had nothing.
    # ⛔ THE PAGE IS THE CLOSED PAGE, NOT THE MERGED SUBSET. `_collect_rest` filters
    # `merged_at is not None` out of a 100-row `state=closed` page, so `len(merged)` can never reach
    # the bound unless nothing was filtered — the guard could not fire on the surface that answers
    # when GraphQL's shared bucket is exhausted (measured here: 100 closed rows, 97 merged).
    # ⛔ THE PAGE BOUND IS A PROPERTY OF THE SURFACE'S ORDERING, NOT OF THE ROW COUNT. `gh pr list`
    # is CREATION-desc, so `--limit 100` bounds CREATION: a PR created 8+ days ago and merged in the
    # last 3h sits outside the page, and a 100-row closed page REALLY does hide merges. REST is
    # `sort=updated&direction=desc`, so a 100-row page whose oldest `updated_at` is 38.65h old covers
    # a 3h window completely (measured on the live target) — truncation there is FALSE, and keying the
    # flag on `len(closed) >= 100` deleted `pr_merged`'s only FAIL arm on the shipped repo (every
    # closed page is full, so a genuinely quiet fleet could never be reported). So the collector
    # decides: creation-ordered page full = truncated; updated-ordered page that still reaches past
    # the window = not truncated; unprovable = truncated (abstain rather than accuse).
    if merged_page_full is None:
        # a caller that cannot say whether its page COVERS the window must abstain: unprovable
        # coverage is truncated, never "complete"
        merged_page_full = True
    out["merged_page_full"] = bool(merged_page_full)
    out["last_merged"] = _iso(max(merged_ts)) if merged_ts else None
    # ⛔ A PR THAT WAS OPENED AND CLOSED UNMERGED STILL COUNTS AS CREATED. The population was built
    # from the OPEN list plus the MERGED list, and `_collect_rest` drops `closed`-without-`merged_at`
    # rows before this ever sees them — so a fleet that opened work and superseded it read
    # `FAIL/NO_PR_CREATED` ("opened no PR in 3.0h") while the closed page held the PRs it opened.
    # `also_created` carries those rows; dedup by number keeps a PR from being counted twice.
    seen, created_rows = set(), []
    for p in list(merged) + list(open_prs) + list(also_created or ()):
        num = p.get("number")
        if num is not None and num in seen:
            continue
        if num is not None:
            seen.add(num)
        created_rows.append(p)
    created_ts = [t for t in (parse_github_ts(p.get("createdAt") or p.get("created_at"))
                              for p in created_rows) if t]
    out["prs_created_in_window"] = len([t for t in created_ts if now - t <= win])
    out["last_created"] = _iso(max(created_ts)) if created_ts else None
    out["open_pr_count"] = len(open_prs)
    out.setdefault("page_full", len(open_prs) >= 100)


def _one_line(txt):
    txt = (txt or "").strip()
    return txt.splitlines()[0][:300] if txt else ""


def _json_list(txt):
    """A parsed JSON list, or None. ⛔ EMPTY STDOUT IS A FAILED READ, not an empty list: `txt or "[]"`
    turned a `gh` that exited 0 with no output (a wrapper that swallows stdout, a truncated pipe)
    into "zero PRs", so `collect_github` returned ok=True and `landers` PASSed over a population it
    never read — the thing `_gh_empty()` exists to forbid. An empty response parses as nothing."""
    if not (txt or "").strip():
        return None
    try:
        d = json.loads(txt)
        return d if isinstance(d, list) else None
    except ValueError:
        return None


def _json_obj(txt):
    if not (txt or "").strip():
        return None
    try:
        d = json.loads(txt)
        return d if isinstance(d, dict) else None
    except ValueError:
        return None


def _iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(ts))


def parse_github_ts(s):
    """GitHub's `2026-10-18T10:49:30Z` → epoch. UTC, converted with calendar.timegm.

    NOT `mktime(strptime(...)) - time.timezone`: that is wrong by an hour for half the year
    (`timezone` is the non-DST offset) and a window comparison inherits the error.
    """
    if not s:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            return calendar.timegm(time.strptime(str(s), fmt))
        except Exception:
            continue
    try:
        return int(datetime.datetime.strptime(str(s), "%Y-%m-%dT%H:%M:%S%z").timestamp())
    except Exception:
        return None


def _run_gh(argv):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=120)
        return p.returncode, (p.stdout or "") + (("\n" + p.stderr) if p.returncode else "")
    except Exception as exc:
        return 127, "%s: %s" % (type(exc).__name__, exc)


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Live facts
# ════════════════════════════════════════════════════════════════════════════════════════════════


def collect_live(cfg, machine=None, now=None, skip=()):
    now = now if now is not None else time.time()
    machine = machine or Machine(cfg.box if cfg.box not in (None, "local") else None)
    machine.log_path = cfg.log_path
    machine.controller_paths = cfg.controller_paths()
    machine.o_dir = cfg.o_dir
    machine.tail_lines = int(getattr(cfg, "log_tail_lines", 6000))
    facts = {"box": cfg.box or "local", "observed_at": _iso(now)}

    log, lines = machine.facts_probe_log()
    facts["log"] = log
    facts["log_events"] = parse_log(lines, now=now)

    hb_raw, hb_err = machine.read_file(os.path.join(cfg.o_dir, "heartbeat"))
    hb = {"path": os.path.join(cfg.o_dir, "heartbeat")}
    if hb_raw is None:
        hb["ok"] = False
        hb["error"] = hb_err
        hb["age_s"] = None
    else:
        txt = hb_raw.strip().split()[0] if hb_raw.strip() else ""
        hb["ok"] = bool(re.match(r"^\d+$", txt))
        hb["raw"] = txt
        # `_age_of` applies the CLOCK_SKEW_TOLERANCE_S rule: a future timestamp is UNKNOWN, never
        # "0s ago". `max(0.0, now - ts)` here made a clock running AHEAD of the canary look fresher
        # than any real reading — on the one datum the respawn proof uses to see the controller move.
        hb["age_s"] = _age_of(now, int(txt)) if hb["ok"] else None
        if not hb["ok"]:
            hb["error"] = "unparseable heartbeat: %r" % hb_raw[:80]
    facts["heartbeat"] = hb

    facts["queue_state"] = read_queue_state(machine, cfg, now)

    facts["controller"] = machine.snapshot_controller()
    facts["launchd"] = machine.launchd_state(cfg.label)
    facts["pane"] = machine.snapshot_pane()
    facts["headroom"] = machine.headroom(cfg.o_dir if cfg.o_dir else "/")

    if "github" in skip:
        facts["github"] = {"ok": False, "error": "skipped by --skip github"}
    else:
        facts["github"] = collect_github(cfg.repo, cfg, now=now)
    return facts


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Static fixtures
# ════════════════════════════════════════════════════════════════════════════════════════════════


class FixtureError(Exception):
    pass


def load_fixture(path):
    try:
        with open(path) as fh:
            d = json.load(fh)
    except Exception as exc:
        raise FixtureError("%s: %s" % (path, exc))
    if not isinstance(d, dict) or "facts" not in d:
        raise FixtureError("%s: a fixture must be an object with a `facts` key" % path)
    # ⛔ THE KEY THAT DECIDES WHETHER ANYTHING IS ASSERTED IS VALIDATED TOO. `_expect` was accepted as
    # any truthy value and then `.items()`-ed, so `"_expect": ["controller_cycling"]` (or a string)
    # raised `AttributeError: 'list' object has no attribute 'items'` out of `run_static` — a traceback
    # with NO fixture rows and exit 1, which CI reads as "a check FAILED" about a fleet that was never
    # evaluated. Exactly the class the `config` guard above already closes, one key over.
    if d.get("_expect") is not None and not isinstance(d["_expect"], dict):
        raise FixtureError("%s: `_expect` must be an object mapping a check name to a status" % path)
    return d


def run_static(paths, only=None):
    """Evaluate fixtures, compare against each fixture's `_expect`.

    Returns (rows, mismatches, skipped). `skipped` are KNOWN checks the caller excluded with `--only`:
    a subset asked for is not a mismatch, and grading it as one made `--static --only X` fail on every
    fixture's other seven expectations (105 mismatches) while the "every fixture matched" branch could
    never print. Loudly reported, never silently dropped.
    """
    rows, mism, skipped = [], [], []
    for path in paths:
        fx = load_fixture(path)
        try:
            cfg = cfg_from_dict(fx.get("config"))
        except (ValueError, TypeError) as exc:
            # ⛔ A BROKEN INPUT IS A USAGE ERROR (exit 3), NOT A FAILED CHECK (exit 1). `Cfg` coerces
            # its numerics, so a hand-edited or half-written fixture (`{"pool_threshold": "many"}`)
            # raised ValueError straight out of `run_static`; `main`'s `except FixtureError` never saw
            # it, the traceback exited 1, and a scheduler read "at least one check FAILed" about a
            # fleet that was never evaluated.
            raise FixtureError("%s: unreadable `config` (%s: %s)"
                               % (path, type(exc).__name__, exc))
        verdicts = evaluate(fx["facts"], cfg, only=only)
        expect = fx.get("_expect") or {}
        got = dict((v.name, v.status) for v in verdicts)
        if not expect:
            # An EMPTY assertion set is not "all zero assertions satisfied": a new fixture with a
            # misspelt `_expects` key contributed no coverage while the runner printed success.
            mism.append((path, "(fixture)", ">=1 expectation", "NO_EXPECT", None))
        else:
            # ⛔ A PARTIAL set is the same defect one key wide: `_expect: {"headroom": "PASS"}` ran
            # seven checks, asserted one, and printed "every fixture matched its declared _expect"
            # with exit 0. Coverage is declared per fixture, so it is required per fixture.
            gap = [n for n in CHECK_ORDER if n not in expect]
            if gap:
                mism.append((path, "(fixture)", "an expectation for all %d checks"
                             % len(CHECK_ORDER), "PARTIAL_EXPECT (%s)" % ",".join(gap), None))
        for name, want in expect.items():
            if name not in got:
                # ⛔ A fixture that names a check which does not exist asserts NOTHING, and the old
                # `continue` then printed "every fixture matched" and exited 0 — a no-op gate that
                # reports the opposite of what it did. (Also covers `--only`, which excludes checks
                # from `got`.) An unknown name is a mismatch; a known name excluded by --only is
                # reported as SKIPPED, loudly, by the caller.
                if only and name in PREDICATES:
                    skipped.append((path, name))
                    continue
                mism.append((path, name, want, "UNKNOWN_CHECK" if name not in PREDICATES
                             else "NOT_EVALUATED", None))
                continue
            if got[name] != want:
                mism.append((path, name, want, got[name],
                             [v for v in verdicts if v.name == name][0]))
        rows.append((path, fx.get("name") or os.path.basename(path), fx.get("note") or "",
                     verdicts, expect))
    return rows, mism, skipped


def fixture_paths(paths, fixtures_dir):
    out = []
    for p in paths or []:
        out.append(p)
    if fixtures_dir:
        out.extend(sorted(glob.glob(os.path.join(fixtures_dir, "*.json"))))
    return out


# The fixture POPULATION is part of the pin: deleting a fixture removes the outcome it pinned and
# every remaining assertion still passes. These names are outcome-critical, so their absence is a
# mismatch rather than a smaller run. (A new fixture is free — this is a lower bound, not a manifest.)
REQUIRED_FIXTURES = (
    "healthy", "controller-absent", "log-silent", "queue-unreadable", "dispatch-refused",
    "empty-backlog-large-pool", "no-pr-merged", "gh-unreadable", "lander-expired",
    "daemon-absent", "headroom-low", "idle-empty-pool",
    # ⛔ EACH OF THESE PINS A BRANCH THAT WAS REACHABLE AND UNPINNED. A fixture set that only shows
    # the happy path lets a predicate be deleted outright without a single red: the FAIL branches of
    # `pr_created`/`pr_merged`, the two headroom floors (the low fixture had BOTH under floor, so
    # either comparison alone still failed), the intent-vs-outcome distinction in `work_dispatched`,
    # and the UNCONFIRMED branch that an intent-only log must fall into.
    "dispatch-intent-not-spawned", "dispatch-unconfirmed", "dispatch-previous-batch-spawn",
    "queue-state-unreadable-newer", "lander-from-another-repo", "merged-surface-truncated",
    "no-pr-created", "idle-no-work", "headroom-disk-only-low", "headroom-mem-only-low",
    "queue-state-read-failed", "queue-state-torn", "queue-state-unaged-authoritative",
    "daemon-protection-unread",
)


def missing_fixtures(paths):
    """Required fixture names absent from `paths` (compared on basename, `.json` stripped)."""
    have = set(os.path.basename(p)[:-5] if p.endswith(".json") else os.path.basename(p)
               for p in paths or [])
    return [n for n in REQUIRED_FIXTURES if n not in have]


def default_fixtures_dir():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", "..", "tests", "fixtures", "outcome-canary"))


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Rendering
# ════════════════════════════════════════════════════════════════════════════════════════════════

MARK = {PASS: "✅ PASS", FAIL: "⛔ FAIL", INCONCLUSIVE: "⚠️  INCONCLUSIVE"}


def render(verdicts, header, not_evaluated=()):
    lines = [header, ""]
    for v in verdicts:
        lines.append("  %-16s %-20s %s" % (MARK[v.status], v.name, v.variant))
        for ln in str(v.evidence).splitlines():
            lines.append("      " + ln)
        if v.status != PASS and v.detail:
            lines.append("      → " + v.detail)
    counts = {}
    for v in verdicts:
        counts[v.status] = counts.get(v.status, 0) + 1
    code = exit_code(verdicts, not_evaluated)
    lines.append("")
    lines.append("summary: %d PASS · %d FAIL · %d INCONCLUSIVE → exit %d"
                 % (counts.get(PASS, 0), counts.get(FAIL, 0), counts.get(INCONCLUSIVE, 0), code))
    if not_evaluated:
        lines.append("⚠️  NOT EVALUATED (excluded by --only, so NOT established): %s"
                     % ", ".join(not_evaluated))
    return "\n".join(lines)


# ════════════════════════════════════════════════════════════════════════════════════════════════
# CLI
# ════════════════════════════════════════════════════════════════════════════════════════════════


class _Parser(argparse.ArgumentParser):
    """argparse exits 2 on a usage error, and 2 is the INCONCLUSIVE code this tool publishes — a
    caller dispatching on the documented codes would read `--bogusflag` as "the fleet is
    inconclusive". Usage errors are 3, everywhere."""

    def error(self, message):
        self.print_usage(sys.stderr)
        print("%s: error: %s" % (self.prog, message), file=sys.stderr)
        raise SystemExit(3)


def build_parser():
    ap = _Parser(
        prog="outcome-canary",
        description="Assert what the fleet PRODUCES, and raise a signal when an outcome is absent.")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--static", action="store_true",
                      help="evaluate injectable fixtures (CI: no network, no process table, no clock)")
    mode.add_argument("--live", action="store_true",
                      help="evaluate this machine, or --box, with the same predicates")
    ap.add_argument("--box", default=None, help="cmux cloud machine name (live mode)")
    ap.add_argument("--o", dest="o_dir", default=None, help="orchestrator state dir (default ~/orchestrator)")
    ap.add_argument("--repo", default=None, help="owner/name for the PR checks")
    ap.add_argument("--label", default=None, help="launchd label (default com.eldato.orchestrator-loop)")
    ap.add_argument("--window-min", type=float, default=None, help="staleness window for log outcomes (default 12)")
    ap.add_argument("--pr-window-min", type=float, default=None, help="window for PR created/merged (default 180)")
    ap.add_argument("--mem-floor-mb", type=float, default=None)
    ap.add_argument("--disk-floor-gb", type=float, default=None)
    ap.add_argument("--pool-threshold", type=int, default=None)
    ap.add_argument("--rest-probe-max", type=int, default=None,
                    help="how many open PRs the REST fallback probes with per-PR detail calls "
                         "(default 25); a PR beyond it is UNPROBED, not green")
    ap.add_argument("--queue-stale-min", type=float, default=None,
                    help="how old an EMPTY pool read may be before it is not evidence (default 90)")
    ap.add_argument("--controller-ws", default=None, help="controller workspace UUID (live send)")
    ap.add_argument("--controller-name", default=None, help="substring of the controller workspace NAME")
    ap.add_argument("--state", dest="state_path", default=None, help="notification state FILE (default_state_path accepts a directory; "
                         "--state does not)")
    ap.add_argument("--facts", default=None,
                    help="live mode: evaluate an injected facts file instead of probing the box "
                         "(the notify/respawn machinery still runs; combine with --dry-run and "
                         "--capture-dir to exercise it with no side effects)")
    ap.add_argument("--capture-dir", default=None,
                    help="capture notifications into this directory instead of sending them; "
                         "reporting is otherwise identical (used by the suite, and to inspect "
                         "exactly what WOULD be sent before pointing it at a controller)")
    ap.add_argument("--only", default=None, help="comma-separated check names")
    ap.add_argument("--skip", default=None, help="comma-separated probes to skip (github)")
    ap.add_argument("--fixture", action="append", default=None, help="a fixture file (repeatable)")
    ap.add_argument("--fixtures-dir", default=None, help="a directory of fixtures")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--dry-run", action="store_true", help="report only: never send, never respawn")
    ap.add_argument("--no-notify", action="store_true",
                    help="compose no messages (does NOT suppress the respawn action — that is "
                         "--no-respawn)")
    ap.add_argument("--no-respawn", action="store_true", help="never attempt a respawn")
    ap.add_argument("--verbose", action="store_true")
    return ap


def build_machine(cfg):
    """The ONE place the machine handle is wired. ⛔ `o_dir` BELONGS HERE.

    It was set only inside `collect_live`, so the object `main` built carried `o_dir=None` for the
    whole run — and `_heartbeat_epoch` returns None without it. The heartbeat leg of the respawn
    proof (`advanced = log_advanced or hb_advanced`) was therefore DEAD in the shipped CLI path, on
    the exact box it exists for (a high-load cell where a successful respawn cannot write the log
    within the 40 s bound), so a SUCCESSFUL respawn was reported and SENT as `RESPAWN DID NOT TAKE`.
    The suite could not see it: its test hands the function a fake that already carries `o_dir`.
    """
    m = Machine(None if cfg.box in (None, "local") else cfg.box)
    m.o_dir = cfg.o_dir
    m.log_path = cfg.log_path
    m.tail_lines = 6000
    m.controller_paths = cfg.controller_paths()
    return m


# ⛔ A PAYLOAD'S OWN `config` IS PART OF THE PAYLOAD. `--facts <fixture>` replayed a fixture through
# the live signal path while `run_static` honoured the SAME key in the SAME file: the fixture pinned
# `lander-from-another-repo` to FAIL in `--static` and to PASS (eight greens, exit 0) through
# `--facts`, because the CLI's repo replaced the file's and `check_landers`' repo_mismatch went
# False — decisions written by another repo's controller credited as landers for this one's PRs. So
# the payload's config is applied, and an EXPLICIT CLI flag still wins (a caller overriding a knob is
# making a decision; the file merely declares a default).
_PINNED_BY_FLAG = (
    ("repo", "repo"), ("label", "label"), ("window_min", "window_s"),
    ("pr_window_min", "pr_window_s"), ("mem_floor_mb", "mem_floor_mb"),
    ("disk_floor_gb", "disk_floor_gb"), ("pool_threshold", "pool_threshold"),
    ("rest_probe_max", "rest_probe_max"), ("queue_stale_min", "queue_stale_s"),
    ("controller_ws", "controller_ws"), ("controller_name", "controller_name"),
    ("state_path", "state_path"),
)


def _payload_cfg(base_cfg, payload, args):
    """Overlay the injected payload's `config` on the CLI config, CLI flags winning."""
    if not isinstance(payload, dict) or not isinstance(payload.get("config"), dict):
        return base_cfg, []
    pinned = set(field for flag, field in _PINNED_BY_FLAG
                 if getattr(args, flag, None) is not None)
    base = base_cfg.as_json()
    applied = []
    for k in sorted(payload["config"]):
        if k in pinned:
            continue
        base[k] = payload["config"][k]
        applied.append(k)
    try:
        return cfg_from_dict(base), applied
    except (ValueError, TypeError) as exc:
        raise FixtureError("--facts %s: unreadable `config` (%s: %s)"
                           % (args.facts, type(exc).__name__, exc))


def cfg_from_args(a):
    o_dir = os.path.abspath(os.path.expanduser(
        a.o_dir or os.environ.get("O") or os.path.join(os.path.expanduser("~"), "orchestrator")))
    kw = {
        "o_dir": o_dir,
        "log_path": os.path.join(o_dir, "logs", "orch-loop.log"),
        "box": _normalize_box(a.box),
        # Declared, so the field is disclosed and a caller can see what it suppressed.
        "state_path": a.state_path or default_state_path(),
        "controller_ws": a.controller_ws,
        "controller_name": a.controller_name,
    }
    if a.repo:
        kw["repo"] = a.repo
    elif a.box and not _is_local_box(a.box):
        # ⛔ THE BOX'S REPO IS NOT THIS MACHINE'S REPO. `_repo_from_plist` opens the LOCAL
        # ~/Library/LaunchAgents/<label>.plist, so a `--box` run graded a remote cell against the
        # repository of whichever cell this machine happens to run — "a healthy fleet for a repo
        # nobody is working on", the outcome that reader's own docstring calls worse than no canary.
        # Reading the plist across the machine boundary is not plumbed, so the honest answer is
        # "unknown": the three PR checks then abstain (GH_UNREADABLE) instead of speaking.
        # ⛔ `local` / `localhost` / `.` ARE THIS BOX — the same test `Machine` uses for `remote` —
        # so the exclusion must not fire for them: it blanked the repo and graded `pr_created`,
        # `pr_merged` and `landers` as GH_UNREADABLE ("no --repo given") on a run that had every
        # input, while still respawning locally and messaging this machine's pane.
        kw["repo"] = ""
    else:
        kw["repo"] = _repo_from_plist(a.label or Cfg.DEFAULTS["label"]) or ""
    if a.label:
        kw["label"] = a.label
    if a.window_min is not None:
        kw["window_s"] = a.window_min * 60.0
    if a.pr_window_min is not None:
        kw["pr_window_s"] = a.pr_window_min * 60.0
    if a.mem_floor_mb is not None:
        kw["mem_floor_mb"] = a.mem_floor_mb
    if a.disk_floor_gb is not None:
        kw["disk_floor_gb"] = a.disk_floor_gb
    if a.pool_threshold is not None:
        kw["pool_threshold"] = a.pool_threshold
    if getattr(a, "rest_probe_max", None) is not None:
        kw["rest_probe_max"] = a.rest_probe_max
    if getattr(a, "queue_stale_min", None) is not None:
        kw["queue_stale_s"] = a.queue_stale_min * 60.0
    if a.capture_dir and not a.state_path:
        # ⛔ A PREVIEW must not silence the real alert. `--capture-dir` records deliveries, so pointing
        # it at the default state file marks a failure "notified" that nobody was ever told about —
        # the next real run then suppresses it. Measured by review. The state for a capture run lives
        # INSIDE the capture directory unless the caller names one explicitly.
        kw["state_path"] = os.path.join(os.path.abspath(os.path.expanduser(a.capture_dir)),
                                        "state.json")
    cfg = Cfg(**kw)
    cfg.log_tail_lines = 6000
    return cfg


def _repo_from_plist(label):
    """The `OR` (owner/name) the DEPLOYED controller targets — read, never assumed.

    A canary that grades PRs against the wrong repo is worse than no canary: it would report a
    healthy fleet for a repo nobody is working on.
    """
    path = _plist_path(label)
    try:
        with open(path) as fh:
            txt = fh.read()
    except Exception:
        return None
    m = re.search(r"<key>OR</key>\s*<string>([^<]+)</string>", txt)
    return m.group(1).strip() if m else None


def main(argv=None):
    ap = build_parser()
    a = ap.parse_args(argv)
    only = [x.strip() for x in a.only.split(",")] if a.only else None
    if only:
        unknown = [x for x in only if x not in PREDICATES]
        if unknown:
            print("outcome-canary: unknown check(s) in --only: %s (known: %s)"
                  % (", ".join(unknown), ", ".join(CHECK_ORDER)), file=sys.stderr)
            return 3
    skip = [x.strip() for x in a.skip.split(",")] if a.skip else []
    # ⛔ A TYPO IN `--skip` WAS A SILENT NO-OP. `--skip githbu` was dropped with no error, no report
    # line and no `not_evaluated` entry: the operator believed a probe was suppressed and the run
    # neither suppressed it nor said so. `--only` already refuses an unknown name (exit 3); `--skip`
    # now does the same, and PRINTS what it suppressed.
    unknown_skip = [x for x in skip if x and x not in SKIPPABLE]
    if unknown_skip:
        print("outcome-canary: unknown probe(s) in --skip: %s (skippable: %s)"
              % (", ".join(unknown_skip), ", ".join(sorted(SKIPPABLE))), file=sys.stderr)
        return 3
    now = time.time()

    if a.static:
        # ⛔ A KNOB THAT CANNOT ACT MUST REFUSE. `--skip` names a live PROBE, and the static path
        # never consults it — so `--static --skip github` exited 0 with `not_evaluated: []` and no
        # line saying the flag did nothing: a silent no-op on a run the operator believed had
        # suppressed a probe. (Same class as the unknown-name check directly above it.)
        if skip:
            print("outcome-canary: --skip %s applies to the LIVE collection only; in --static use "
                  "--only to narrow which checks are asserted" % ",".join(skip), file=sys.stderr)
            return 3
        # ⛔ THE SAME RULE FOR THE OTHER LIVE-ONLY KNOBS. `--static --facts X` loaded NOTHING and
        # exited 0 over 30 passing fixtures — a green that looks like the payload was graded, and the
        # only tells are `mode` and the fixture names. A capture directory likewise has no meaning
        # when nothing is composed.
        for flag, given in (("--facts", a.facts), ("--capture-dir", a.capture_dir)):
            if given:
                print("outcome-canary: %s applies to the LIVE path only; --static grades FIXTURES"
                      % flag, file=sys.stderr)
                return 3
        if a.state_path:
            print("outcome-canary: --state applies to the LIVE path only (nothing is notified in "
                  "--static)", file=sys.stderr)
            return 3
        paths = fixture_paths(a.fixture, a.fixtures_dir if a.fixtures_dir is not None
                              else (None if a.fixture else default_fixtures_dir()))
        if not paths:
            print("outcome-canary: no fixtures found (pass --fixture or --fixtures-dir)", file=sys.stderr)
            return 3
        try:
            rows, mism, skipped = run_static(paths, only=only)
        except FixtureError as exc:
            print("outcome-canary: %s" % exc, file=sys.stderr)
            return 3        # nothing was evaluated; 1 means "at least one check FAILed"
        if a.fixtures_dir is not None or not a.fixture:
            # The POPULATION is part of the pin: a deleted fixture removes the outcome it pinned and
            # every remaining assertion still passes. Only checked when this run claims to cover a
            # directory (an explicit --fixture list is deliberately a subset).
            for name in missing_fixtures(paths):
                mism.append((a.fixtures_dir or default_fixtures_dir(), "(fixture-set)",
                             "fixture present", "MISSING_FIXTURE (%s)" % name, None))
        # WHAT WAS ACTUALLY LEFT UNGRADED — read from the VERDICTS, so `--only` naming all eight
        # checks is NOT a narrowed run (it excluded nothing) and an absent `--only` never is either.
        unanswered = [n for n in CHECK_ORDER
                      if n not in set(v.name for _p, _n, _nt, vs, _e in rows for v in vs)]
        narrowed = bool(unanswered)
        if a.json:
            # ⛔ THE MACHINE-READABLE REPORT CARRIES THE SAME TWO DISCLOSURES AS THE LIVE ONE. An
            # `--only` run exits 2 and, without these keys, a consumer saw "every fixture matched"
            # and had no way to know 7 of 8 checks were never asserted.
            print(json.dumps({"mode": "static",
                              # ⛔ THE EXIT THE PROCESS ACTUALLY RETURNS (below): a drifted
                              # fixture is 1, a narrowed run 2, otherwise 0. Computing it from the
                              # verdicts instead described a code this mode never produces.
                              # ⛔ NARROWING IS AN EXCLUSION, NOT A FLAG. `--only` naming all eight
                              # checks excluded nothing, so `not_evaluated: []` sat beside
                              # `exit: 2` and a "(the other 0 check(s) were NOT asserted)" note.
                              "exit": (1 if mism else (2 if narrowed else 0)),
                              "not_evaluated": unanswered,
                              "fixtures": [
                {"path": p, "name": n, "note": note,
                 "verdicts": [v.as_json() for v in vs], "expect": ex}
                for p, n, note, vs, ex in rows], "skipped": [
                    {"path": p, "check": c} for p, c in skipped], "mismatches": [
                    {"path": p, "check": c, "expected": w, "got": g,
                     "variant": (vv.variant if vv is not None else None),
                     "evidence": (vv.evidence if vv is not None else None)}
                    for p, c, w, g, vv in mism]}, indent=1))
        else:
            for p, n, note, vs, ex in rows:
                hdr = "fixture %s (%s)%s" % (n, os.path.basename(p), (" — " + note) if note else "")
                # ⛔ `--only` NARROWS, IT DOES NOT CERTIFY — so the checks it EXCLUDED are passed to
                # `render` exactly as the live path passes them. Without this every block printed
                # "→ exit 0" while the process exited 2, and the only correction was a footnote: the
                # line an operator quotes is the one that was wrong.
                # ⛔ THE COMPLEMENT OF WHAT WAS GRADED — read from the VERDICTS, exactly as the live
                # path does. Deriving it from the `--only` list inverted the report whenever the flag
                # was ABSENT (`set(only or [])` is empty, so all eight were "NOT EVALUATED") and made
                # every static block print "→ exit 2", including the all-green `healthy` fixture.
                print(render(vs, hdr, not_evaluated=[n for n in CHECK_ORDER
                                                     if n not in set(v.name for v in vs)]))
                print()
            if skipped:
                print("⚠️  %d expectation(s) NOT ASSERTED because --only %s excluded them:"
                      % (len(skipped), ",".join(only or [])))
                for p, c in skipped[:12]:
                    print("   %s: %s" % (os.path.basename(p), c))
            if mism:
                print("⛔ %d predicate mismatch(es) against the fixture's own _expect:" % len(mism))
                for p, c, w, g, vv in mism:
                    print("   %s: %s expected %s, got %s%s"
                          % (os.path.basename(p), c, w, g,
                             (" (%s)" % vv.variant) if vv is not None else ""))
                    if vv is not None:
                        print("      evidence: %s" % str(vv.evidence).replace("\n", " | ")[:300])
            else:
                if narrowed:
                    # the COUNT and the NAMES come from what was graded, not from the flag: `--only`
                    # naming all eight excluded nothing and used to print "the other 0 check(s)".
                    print("✅ every fixture matched its declared _expect (note: %d check(s) were NOT "
                          "asserted: %s)" % (len(unanswered), ",".join(unanswered)))
                else:
                    print("✅ every fixture matched its declared _expect")
        if mism:
            return 1
        # ⛔ `--only` NARROWS, IT DOES NOT CERTIFY — the same rule the live path enforces. A green
        # static run that asserted 1 of 8 checks and exited 0 would be quoted as "the suite passes".
        return 2 if narrowed else 0

    # ── live ────────────────────────────────────────────────────────────────────────────────
    cfg = cfg_from_args(a)
    # ⛔ A NUMERIC FLAG IS A USAGE ERROR TOO. `--pr-window-min 1e300` raised
    # `OverflowError: timestamp out of range` inside `_collect_graphql` — a traceback, NO verdicts and
    # exit 1, which is the row that means "a check FAILed". `nan` raised `ValueError` the same way.
    # Every knob is bounded here, before any collection, and reports as the usage error it is.
    for knob in Cfg.NUMERIC_KNOBS:
        val = getattr(cfg, knob, None)
        if not _is_age(val):          # a number, and a bool is not one
            print("outcome-canary: %s must be a number (got %r)" % (knob, val), file=sys.stderr)
            return 3
        if val != val or val in (float("inf"), float("-inf")):
            print("outcome-canary: %s must be finite (got %r)" % (knob, val), file=sys.stderr)
            return 3
        if val < 0:
            print("outcome-canary: %s must not be negative (got %r)" % (knob, val), file=sys.stderr)
            return 3
        if knob in ("window_s", "pr_window_s", "queue_stale_s") and not (0 < val <= 30 * 86400):
            print("outcome-canary: %s must be between 1s and 30d (got %r)" % (knob, val),
                  file=sys.stderr)
            return 3

    reported_cfg_from = []
    # ⛔ ONE INITIALISATION, BEFORE EITHER BRANCH. `collect_error` was assigned only in the
    # collector's `except`, and the injected path reads it too — so `--facts <{"facts": null}>` (what
    # a generator or a truncated writer produces, and a shape the WRAPPER form explicitly permits)
    # raised `UnboundLocalError: cannot access local variable 'collect_error'` at the line that was
    # trying to REPORT a failure: a traceback, zero verdicts, no signal, and exit 1 — the code that
    # means "at least one check FAILED".
    collect_error = None
    if a.facts:
        # INJECTED FACTS through the LIVE path. The predicates are the same ones `--static` runs;
        # what this adds is the SIGNAL machinery (compose → de-duplicate → send/respawn) so that
        # machinery can be executed against a known-bad shape with no box and no clock.
        try:
            with open(a.facts) as fh:
                inj = json.load(fh)
            facts = inj.get("facts", inj)
            cfg, reported_cfg = _payload_cfg(cfg, inj, a)
            if reported_cfg:
                reported_cfg_from = reported_cfg
        except Exception as exc:
            print("outcome-canary: cannot read --facts %s: %s" % (a.facts, exc), file=sys.stderr)
            return 3
        if facts is None:
            # A null body is a MALFORMED PAYLOAD, not a collector failure: nothing was collected and
            # nothing raised, so grading it `COLLECTOR_ERROR` would put a fabricated exception in the
            # report. It is the same usage error as an unreadable file.
            print("outcome-canary: --facts %s carries no fact set (its `facts` value is null); "
                  "nothing was evaluated" % a.facts, file=sys.stderr)
            return 3
    # ⛔ BUILT UNCONDITIONALLY, FROM THE EFFECTIVE CFG (after any payload config) AND BEFORE the
    # collection that uses it. It was created in `main` above the injection branch, and moving the
    # config overlay meant the payload's `remote`/box identity had to be honoured — but building it
    # only in the `else` left the SIGNAL path (`machine.remote`, `machine.local()`) with no object at
    # all. One builder, one place, both branches.
    machine = build_machine(cfg)
    if not a.facts:
        try:
            facts = collect_live(cfg, machine=machine, now=now, skip=skip)
        except Exception as exc:
            # ⛔ AN UNEXPECTED COLLECTOR FAILURE IS NOT A VERDICT. It used to escape as a traceback
            # with no verdicts and exit 1 — indistinguishable from "a check FAILed". The run now
            # prints the failure AND reports every check as INCONCLUSIVE, so the exit code says
            # "could not evaluate" rather than either green or red.
            print("outcome-canary: the live collector raised %s: %s"
                  % (type(exc).__name__, exc), file=sys.stderr)
            traceback.print_exc()
            facts = None
            collect_error = "%s: %s" % (type(exc).__name__, exc)
    if facts is None:
        verdicts = [V(name, INCONCLUSIVE, "COLLECTOR_ERROR",
                      "the live collection raised %s" % collect_error,
                      "no fact was collected, so nothing about this check is established.")
                    for name in CHECK_ORDER]
        not_evaluated = []
        code = 2
    else:
        verdicts = evaluate(facts, cfg, only=only)
        not_evaluated = [n for n in CHECK_ORDER if n not in set(v.name for v in verdicts)]
        code = exit_code(verdicts, not_evaluated)

    obs_iso = _iso(now)
    # ⛔ AN INJECTED FACT SET IS NOT A LIVE OBSERVATION. `--facts` replaced the whole fact dict, yet the
    # header still said "LIVE" and stamped the RUN's clock — so two runs supplying the same file
    # minutes or days apart were indistinguishable, in exactly the field a reader uses to judge
    # currency. The provenance is now stated, and an `observed_at` in the payload is preferred to the
    # run clock.
    _injected = bool(a.facts)
    _obs_at = facts.get("observed_at") if isinstance(facts, dict) else None
    if _injected and _obs_at:
        obs_iso = str(_obs_at)
    header = ("outcome canary — %s box=%s repo=%s  %s\n"
              "window=%.0fs  pr-window=%.0fs  mem-floor=%.0fMiB  disk-floor=%.0fGiB  pool-threshold=%d"
              % ("FACTS INJECTED (%s; not a live observation)" % a.facts if _injected else "LIVE",
                 cfg.box, cfg.repo or "(unknown — pass --repo)", obs_iso, cfg.window_s,
                 cfg.pr_window_s, cfg.mem_floor_mb, cfg.disk_floor_gb, cfg.pool_threshold))

    reported = {"respawn": None, "sent": [], "captured": [], "suppressed": [],
                "not_delivered": [],
                "facts": ("injected: %s" % a.facts) if _injected else "live collection",
                # WHICH KNOBS CAME FROM THE PAYLOAD: the caller must be able to see that the file
                # graded itself with its own repo/windows, not with the CLI's.
                "config_from_payload": reported_cfg_from}

    # (a) respawn — ONLY when the controller is genuinely absent
    ctrl = [v for v in verdicts if v.name == "controller_cycling"]
    ctrl_v = ctrl[0] if ctrl else None
    if ctrl_v is not None and ctrl_v.variant in RESPAWN_TRIGGERS and not a.no_respawn:
        rr = attempt_respawn(ctrl_v, cfg, machine, dry_run=a.dry_run)
        reported["respawn"] = rr
        # Re-check after a successful respawn so the report reflects what is TRUE now.
        if rr.get("took"):
            # ⛔ THIS REPLACES THE INJECTED FACT SET WITH A LIVE ONE. That is the right thing to do
            # after a respawn (the report must say what is true NOW), and silently mixing the two
            # would make the verdicts unattributable — so the swap is recorded in the report.
            if _injected:
                reported["facts"] = ("injected for the first read (%s); RE-COLLECTED LIVE after the "
                                     "respawn" % a.facts)
            try:
                facts2 = collect_live(cfg, machine=machine, now=time.time(), skip=skip)
            except Exception as exc:
                # ⛔ THE SECOND COLLECTION IS THE ONE THAT RUNS AFTER A DESTRUCTIVE ACTION. It was
                # the ONLY unguarded `collect_live` call, so an exception here escaped `main` with a
                # traceback, no report, no message — and exit 1, hiding the `launchctl` action the
                # run had just taken.
                reported["respawn"] = dict(rr, after_collect_error="%s: %s"
                                           % (type(exc).__name__, exc))
                verdicts = [V(name, INCONCLUSIVE, "COLLECTOR_ERROR",
                              "the post-respawn re-read raised %s: %s"
                              % (type(exc).__name__, exc),
                              "the respawn ran, but what happened afterwards was not read, so "
                              "nothing about this check is established.")
                            for name in CHECK_ORDER]
                not_evaluated = []
                code = 2
                facts2 = None
            if facts2 is not None:
                # ⛔ THE PROVENANCE MUST FOLLOW THE VERDICTS. These describe the payload that
                # produced them, and the verdicts just came from a LIVE read: leaving them alone
                # printed "FACTS INJECTED (…; not a live observation)" over live verdicts and emitted
                # `facts_injected: true` beside a live `observed_at` — the two fields a consumer uses
                # to judge currency, contradicting `facts_source` in the same payload.
                prov = _post_respawn_provenance(cfg, a.facts)
                _injected, obs_iso, header = prov["injected"], prov["observed_at"], prov["header"]
                reported["facts"] = prov["facts"]
                verdicts = evaluate(facts2, cfg, only=only)
                not_evaluated = [n for n in CHECK_ORDER if n not in set(v.name for v in verdicts)]
                code = exit_code(verdicts, not_evaluated)
    elif ctrl_v is not None and ctrl_v.variant in RESPAWN_TRIGGERS:
        reported["respawn"] = {"attempted": False, "took": False,
                               "detail": "suppressed by --no-respawn", "commands": []}
    if a.no_notify:
        # ⛔ A SUPPRESSED NOTIFY IS NOT "NOTHING NEEDED SENDING". `--skip` and `--no-respawn` both
        # disclose what they suppressed; this flag left `signal.sent`/`suppressed` empty, so an
        # operator asking "why did the controller never hear about this FAIL" got no answer.
        reported["notify"] = "suppressed by --no-notify"

    # (b)+(c) notify — change-only, sanctioned path, never mid-turn
    state = None
    if not a.no_notify:
        # A PREVIEW READS THE STATE AND DOES NOT WRITE THE *DEFAULT* ONE (see `State.persist`). A
        # caller who NAMED a destination — `--state` or `--capture-dir` — has declared where its state
        # lives, and the same rule already governs the capture path; what must never happen is a
        # bare `--dry-run` mutating the state file the NEXT REAL POLL reads.
        state = State(cfg.state_path, cfg.box,
                      persist=not (a.dry_run and not (a.state_path or a.capture_dir)))
        if getattr(state, "repaired", False):
            reported["state_repaired"] = ("%s (version %s)" % (cfg.state_path,
                                                               state.data.get("version")))
        to_send, suppressed = plan_notifications(verdicts, state, capturing=bool(a.capture_dir))
        reported["suppressed"] = [v.key for v in suppressed]
        # which of those are AMBIGUOUS (nothing confirmed) rather than delivered
        reported["suppressed_ambiguous"] = [v.key for v in suppressed if state.is_ambiguous(v.key)]
        extra = None
        if reported["respawn"]:
            rr = reported["respawn"]
            extra = ["RESPAWN", "  " + (rr.get("detail") or "not attempted")]
            for argv, rc, out in rr.get("commands") or []:
                extra.append("  $ %s  → rc=%s %s" % (" ".join(argv), rc, (out or "")[:200]))
        for v in to_send:
            # ⛔ A REMOTE BOX'S OUTCOME CANNOT BE MESSAGED FROM HERE. `--box` scopes the FACTS and the
            # state key, but `find_controller_workspace`/`send_message` run on the LOCAL cmux socket —
            # so a run for cell-2 discovered box A's controller and delivered into it, and the report
            # recorded `delivered` for a recipient that cannot act on cell-2. The respawn path already
            # refuses honestly for a remote box (`NOT ATTEMPTED (remote)`); the send path now does too.
            if machine.remote:
                detail = ("NOT DELIVERED: box %s is REMOTE — the cmux socket, and therefore the "
                          "controller pane, belongs to THIS machine. A remote box's controller "
                          "cannot be messaged from here." % cfg.box)
                reported["not_delivered"].append({
                    "check": v.name, "variant": v.variant, "detail": detail, "ws": None,
                    "ws_resolution": "refused before discovery: the box is remote",
                    "message": compose_message(v, verdicts, cfg.box, obs_iso, extra_lines=extra)})
                continue
            ws = cfg.controller_ws
            ws_why = "--controller-ws"
            if not ws:
                # cmux discovery and the send must run on the LOCAL box: the socket lives here,
                # and a remote `cmux workspace list` would answer for a different fleet.
                ws, ws_why = find_controller_workspace(machine.local(), cfg.controller_name)
            # ⛔ COMPOSE ONCE, BEFORE the send, extras included. The respawn outcome is known before
            # this loop, and it must be in the bytes the controller RECEIVES: the documented wiring is
            # launchd, where stdout is a log nobody reads and the message is the only channel. This
            # used to compose the extras AFTER sending, so `RESPAWN TOOK`/`DID NOT TAKE` reached only
            # the report and the NOT-DELIVERED dump printed a message different from the one attempted.
            body = compose_message(v, verdicts, cfg.box, obs_iso, extra_lines=extra)
            delivered, detail = (capture_message(body, a.capture_dir, v) if a.capture_dir
                                 else send_message(body, cfg, machine.local(), dry_run=a.dry_run,
                                                   ws=ws,
                                                   label="canary-%s-%s" % (v.name, v.variant)))
            if delivered:
                # ⛔ A CAPTURE IS NOT A DELIVERY. `--capture-dir` writes the composed message to a
                # directory instead of sending it, and marking it delivered records in the PERSISTENT
                # state that somebody was told: the next real run then suppresses a real FAIL with no
                # human involved. (Measured: capture run → state `delivered: true` → the live run
                # printed `suppressed`.) A capture is recorded beside the sends, never as one.
                if a.capture_dir:
                    reported["captured"].append({"check": v.name, "variant": v.variant,
                                                 "detail": detail})
                    state.mark_captured(v.key, now)
                    state.clear_others(v.name, keep=v.key)
                    try:
                        state.save()
                    except Exception as exc:
                        reported["state_error"] = "%s: %s" % (type(exc).__name__, exc)
                    continue
                state.clear_ambiguous(v.key)
                state.clear_others(v.name, keep=v.key)
                state.mark(v.key, now, delivered=True)
                try:
                    state.save()     # durable BEFORE the next send: a later failure cannot re-send it
                except Exception as exc:
                    reported["state_error"] = "%s: %s" % (type(exc).__name__, exc)
                reported["sent"].append({"check": v.name, "variant": v.variant,
                                         "bytes": len(body), "ws": ws, "detail": detail})
            else:
                if _send_rc_is_ambiguous(detail):
                    # Bytes may already be in the composer: suppress the retry, but keep it visible.
                    state.mark_ambiguous(v.key, now)
                reported["not_delivered"].append({"check": v.name, "variant": v.variant,
                                                  "detail": detail, "ws": ws, "ws_resolution": ws_why,
                                                  "message": body})
            if a.verbose:
                print(body, file=sys.stderr)
        state.data["boxes"][cfg.box]["last_run"] = now
        state.data["boxes"][cfg.box]["last_status"] = dict((v.name, v.status) for v in verdicts)
        # ⛔ An unwritable state path must not (a) crash the run after sending, so the JSON report is
        # never printed and the exit code imitates a FAIL, nor (b) silently turn "one message per
        # state change" into "one per poll", re-stacking the same alert. A full disk is exactly when
        # `headroom` is FAILing and the canary is most active, so this is the likeliest moment.
        try:
            state.save()
        except Exception as exc:
            reported["state_error"] = "%s: %s" % (type(exc).__name__, exc)
        # ⛔ AN OUTCOME, NOT AN INTENT. `state.persist` says whether the run was ALLOWED to write;
        # the print says "Persisted this run", so a failed write (a full disk, an unwritable path —
        # the likeliest moment for this branch at all) must not report yes.
        reported["state_persisted"] = bool(state.persist) and not reported.get("state_error")

    if a.json:
        # ⛔ THE PROVENANCE IS PART OF THE PAYLOAD. `reported["facts"]` was written for the text
        # header and then read nowhere, so `--facts X --json` emitted `"mode": "live"` with an
        # injected fact set and NO key anywhere saying so — a JSON consumer recorded fixture facts
        # as a live observation of `box`.
        print(json.dumps({"mode": "live", "box": cfg.box, "repo": cfg.repo,
                          "observed_at": obs_iso,
                          "facts_source": reported.get("facts"),
                          "facts_injected": _injected,
                          "config": cfg.as_json(),
                          "verdicts": [v.as_json() for v in verdicts],
                          "exit": code,
                          "not_evaluated": not_evaluated,
                          "signal": {
                              "respawn": reported["respawn"],
                              "sent": reported["sent"],
                              "captured": reported.get("captured") or [],
                              "config_from_payload": reported.get("config_from_payload") or [],
                              "suppressed": reported["suppressed"],
                              "suppressed_ambiguous": reported.get("suppressed_ambiguous") or [],
                              "not_delivered": reported["not_delivered"],
                              "state_error": reported.get("state_error"),
                              "state_repaired": reported.get("state_repaired"),
                              "state_persisted": reported.get("state_persisted"),
                              "notify": reported.get("notify"),
                          }}, indent=1))
        return code

    print(render(verdicts, header, not_evaluated))
    if reported.get("state_repaired"):
        # ⛔ SAY WHAT HAPPENED TO THE RECORD, NOT WHAT HAPPENED TO THE DISK. It was IGNORED and the run
        # continues on an empty one; whether anything was written is a separate fact
        # (`state_persisted`), and on an unwritable path nothing is (a bare `--dry-run` also writes
        # nothing, but `--dry-run --state P` DOES persist — so the flag is reported, never assumed).
        # Telling an operator it "was replaced" when the file is untouched sends them looking at the
        # wrong thing.
        print("\n\u26a0\ufe0f NOTIFICATION STATE IGNORED (%s) — its contents were not readable as a "
              "per-box record, so this run used an empty one and delivery de-duplication restarted "
              "empty (a re-broken check may speak again). Persisted this run: %s."
              % (reported["state_repaired"],
                 "yes" if reported.get("state_persisted") else "no"))
    if reported["respawn"]:
        rr = reported["respawn"]
        print("\nrespawn: %s" % (rr.get("detail") or "not attempted"))
        for argv, rc, out in rr.get("commands") or []:
            print("  $ %s  → rc=%s %s" % (" ".join(argv), rc, (out or "")[:200]))
    if reported["sent"]:
        print("\nnotified (delivered): %s" % ", ".join(
            "%s/%s" % (s["check"], s["variant"]) for s in reported["sent"]))
    # ⛔ TWO DIFFERENT CLAIMS. `plan_notifications` suppresses on `state.notified` (someone WAS told)
    # OR on `state.is_ambiguous` (the bytes may be sitting in a composer and nothing is confirmed) —
    # and the report called both "already notified". An operator reading that about an AMBIGUOUS
    # marker stops looking, which is the exact silence the marker exists to make visible.
    if reported.get("notify"):
        print("\n%s — no message was composed or sent for this run"
              % reported["notify"])
    if reported.get("captured"):
        print("\ncaptured (NOT sent — --capture-dir): %s"
              % ", ".join("%s|%s" % (c["check"], c["variant"]) for c in reported["captured"]))
    if reported["suppressed"]:
        told = [k for k in reported["suppressed"] if k not in (reported.get("suppressed_ambiguous")
                                                               or ())]
        unsure = reported.get("suppressed_ambiguous") or []
        if told:
            print("\nsuppressed (state unchanged, already notified): %s" % ", ".join(told))
        if unsure:
            print("\nsuppressed (last attempt was AMBIGUOUS — delivery NOT confirmed; the bytes may "
                  "be in the composer, so it is not retried blind): %s" % ", ".join(unsure))
    if reported.get("state_error"):
        # Loud on purpose: with an unwritable state file the notifier cannot honour "one message per
        # state change", and the next poll will re-send. The run did not crash — but it must say so.
        print("\n\u26d4 NOTIFICATION STATE NOT PERSISTED (%s) — delivery de-duplication is degraded; "
              "the next poll may re-send." % reported["state_error"])
    for nd in reported["not_delivered"]:
        print("\n⛔ NOT DELIVERED: %s/%s — %s" % (nd["check"], nd["variant"], nd["detail"]))
        if nd.get("ws_resolution"):
            print("   workspace resolution: %s" % nd["ws_resolution"])
        if _send_rc_is_ambiguous(nd["detail"]):
            print("   (AMBIGUOUS: the bytes may already be in the pane. NOT recorded as sent and "
                  "NOT blind-retried — suppressed until the failure shape changes or the check "
                  "recovers, so a wedged lane is not given a second brief.)")
        else:
            print("   (REFUSED: nothing was consumed, so the next poll retries it)")
        print("   --- message that was composed ---")
        for ln in nd["message"].splitlines():
            print("   | " + ln)
    return code


if __name__ == "__main__":
    sys.exit(main())
