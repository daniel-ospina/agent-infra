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
  3. work_dispatched      a `[dispatch] … -> <issue>` line exists within the window. THIS is the
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
import time

# ── status vocabulary ────────────────────────────────────────────────────────────────────────────
PASS = "PASS"
FAIL = "FAIL"
INCONCLUSIVE = "INCONCLUSIVE"

# ── the checks, in report order ──────────────────────────────────────────────────────────────────
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
        # Which README/doc a failure points at is per-check (ORIENTATION), not configurable.
        "respawn_timeout_s": 40.0,
        "label": "com.eldato.orchestrator-loop",
        "repo": "",
        # Set by cfg_from_args / fixtures; None is a legitimate value ("not configured").
        "o_dir": None,
        "log_path": None,
        "box": "local",
        "controller_ws": None,
        "state_path": None,
    }

    FIELDS = (
        "window_s",
        "pr_window_s",
        "mem_floor_mb",
        "disk_floor_gb",
        "pool_threshold",
        "respawn_timeout_s",
        "label",
        "repo",
        "o_dir",
        "log_path",
        "box",
        "controller_ws",
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
        for k in ("window_s", "pr_window_s", "mem_floor_mb", "disk_floor_gb",
                  "respawn_timeout_s"):
            setattr(self, k, float(getattr(self, k)))
        self.pool_threshold = int(self.pool_threshold)

    def controller_paths(self):
        """The controller script(s) for THIS cell: `$O/orch-loop.sh`, plus the harness copy if a
        deployed layout keeps one. Derived from the same `$O` the log and heartbeat come from — a
        separate notion of "where the controller lives" is how two verdicts drift apart."""
        out = [os.path.join(self.o_dir, "orch-loop.sh")]
        harness = os.path.join(self.o_dir, "orchestrator-harness", "orch-loop.sh")
        if harness not in out:
            out.append(harness)
        return out

    def as_json(self):
        """The subset a FIXTURE may declare — the inputs that change a verdict."""
        return {
            "window_s": self.window_s,
            "pr_window_s": self.pr_window_s,
            "mem_floor_mb": self.mem_floor_mb,
            "disk_floor_gb": self.disk_floor_gb,
            "pool_threshold": self.pool_threshold,
            "label": self.label,
            "repo": self.repo,
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

# The refresh's own vocabulary (orch-loop.sh `queue_state_token`). One vocabulary, parsed not
# re-invented: EMPTY / READ(n) / PARTIAL(<labels>) / UNREADABLE / UNKNOWN.
RE_QUEUE_KIND = re.compile(r"^(?P<kind>EMPTY|UNREADABLE|UNKNOWN|READ\((?P<n>\d+)\)|PARTIAL\((?P<part>[^)]*)\))")
RE_AGE_SUFFIX = re.compile(r"\((?P<age>\d+)(?P<unit>[smh])\)")

MONTHS = {
    "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
    "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
}
DOW = {"Mon": 0, "Tue": 1, "Wed": 2, "Thu": 3, "Fri": 4, "Sat": 5, "Sun": 6}


def parse_cycle_ts(ts):
    """'Sun Oct 18 07:47:44 EST 2026' → epoch seconds, or None. Both measured formats accepted.

    The timezone token is DROPPED and the rest is interpreted as LOCAL time, which is what the loop
    wrote it in. `time.strptime('%Z')` only understands UTC/GMT, so parsing it would silently
    mis-handle EST/EDT by an hour — a wrong age is worse than an unknown one.
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
        return time.mktime((int(gd["year"]), MONTHS[gd["mon"]], int(gd["day"]),
                            hh, mm, ss, 0, 1, -1))
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
                       "dispatch_skipped", "armed", "railed"):
            for rec in ev[bucket]:
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
        age = e.get("age_s")
        if require_age and age is None:
            continue
        if age is not None and age > window_s:
            continue
        if best is None or (age is not None and (best.get("age_s") is None or age < best["age_s"])):
            best = e
    return best


def newest(events):
    """The newest event by age, fresh or not (for EVIDENCE about a stale thing)."""
    best = None
    for e in events or []:
        age = e.get("age_s")
        if best is None:
            best = e
            continue
        if age is None:
            continue
        if best.get("age_s") is None or age < best["age_s"]:
            best = e
    return best


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
    if age is None:
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
    pids = ctrl.get("pids") or []
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
    log_age = log.get("age_s")
    log_txt = "%s mtime %s (%s)" % (
        log.get("path") or "<log>",
        log.get("mtime_iso") or "?",
        _age_txt(log_age),
    )
    hb_txt = "heartbeat %s" % (_age_txt(hb.get("age_s")) if hb.get("age_s") is not None else "absent/unreadable")

    # ── ABSTAIN: the process table itself could not be read ──────────────────────────────
    if ctrl.get("ok") is False:
        return V("controller_cycling", INCONCLUSIVE, "PROCESS_TABLE_UNREADABLE",
                 "process table read FAILED (%s)\nlaunchd %s: %s\n%s"
                 % (ctrl.get("error") or "no error recorded", lc, lc_txt, log_txt),
                 "whether a controller exists is UNKNOWN — the `ps` read did not happen. This is "
                 "NOT absence, and absence is the only state that respawns, so an unreadable "
                 "table must never reach it. Not green.")

    # ── ABSENT: no process AND launchd has no pid ────────────────────────────────────────────
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

    cycles = [h for h in (f.get("log_events") or {}).get("headers") or []
              if h.get("age_s") is not None and h["age_s"] <= win]
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
        return V("queue_readable", INCONCLUSIVE, "NO_REFRESH",
                 "no cycle header inside the %.0fs window\nlast: %s"
                 % (win, allh.get("raw") if allh else "none in the parsed log tail"),
                 "the refresh did not run in the window, so its verdict cannot be read. Not green.")

    tok = parse_queue_token(hdr.get("queue_token"))
    raw_tok = hdr.get("queue_token") or "(absent)"
    state_txt = _queue_state_file_txt(f)
    backlog = hdr.get("backlog")

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
    if tok["kind"] == "EMPTY" and backlog is None:
        return V("queue_readable", INCONCLUSIVE, "HEADER_INCOMPLETE",
                 "header: %s has no backlog= field, so 'empty' cannot be checked against it"
                 % hdr.get("raw"),
                 "an incomplete header is not a readable verdict.")
    if isinstance(backlog, int) and backlog == 0 \
            and isinstance(pool, int) and pool >= c.pool_threshold:
        return V("queue_readable", FAIL, "EMPTY_WITH_LARGE_POOL",
                 "header: %s\nbacklog=0 while the refresh had just READ %d issue(s) "
                 "(threshold %d)\n%s" % (hdr.get("raw"), pool, c.pool_threshold, state_txt),
                 "the refresh produced an EMPTY backlog out of a pool it had just read as large. "
                 "Either the pool read was wrong (a refresh defect, #1931) or every issue is "
                 "already claimed — the evidence above is what tells the two apart.")

    return V("queue_readable", PASS, "READABLE",
             "header: %s\npool token: %s\n%s\nbacklog=%s"
             % (hdr.get("raw"), raw_tok, state_txt, backlog))


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
                   if r.get("age_s") is not None and r["age_s"] <= win]
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
    ok = newest_with_age(events.get("dispatch_ok"), win)
    if ok is not None:
        # PASS is PASS by the outcome, but the refusals are EVIDENCE and a pass that hides them is
        # the green-while-broken failure this whole file exists to end. They are printed, always.
        return V("work_dispatched", PASS, "DISPATCHED",
                 "dispatch line (%s): %s\n%d issue(s) dispatched inside the %.0fs window%s"
                 % (_age_txt(ok.get("age_s")), ok.get("raw"), ok.get("issue_count") or 0, win,
                    refused_txt))

    refused = refused_all
    empty = newest_with_age(events.get("dispatch_empty"), win)
    skipped = newest_with_age(events.get("dispatch_skipped"), win)
    hdr = newest_with_age(events.get("headers"), win)
    backlog = hdr.get("backlog") if hdr else None
    pool = parse_queue_token(hdr.get("queue_token") if hdr else "").get("pool")
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
    evidence = "\n".join(ev_lines)

    # POSITIVE evidence that work existed and none of it went out → FAIL. This is the check's whole
    # point; it is the branch that catches "everything is up and nothing ships".
    if refused:
        return V("work_dispatched", FAIL, "NOT_DISPATCHED", evidence,
                 "%d dispatch attempt(s) were REFUSED in the window and nothing was dispatched. "
                 "The controller is cycling, the queue is readable, and no work is going out."
                 % len(refused))
    if isinstance(backlog, int) and backlog > 0 and skipped is not None:
        return V("work_dispatched", FAIL, "NO_DISPATCH_GATED", evidence,
                 "the refresh reported %d candidate(s) and the dispatch gate skipped every cycle "
                 "in the window (reason on the [dispatch] skipped line above). The outcome is "
                 "absent — the evidence names WHY, which distinguishes a gated fleet from a "
                 "silently dead one." % backlog)
    if isinstance(backlog, int) and backlog > 0:
        return V("work_dispatched", FAIL, "NO_DISPATCH", evidence,
                 "the refresh reported %d candidate(s) and no dispatch line was written in the "
                 "window. Work existed and did not move." % backlog)

    # No dispatch, no refusals, nothing in the backlog: is that IDLE or BLIND?
    pool_kind = parse_queue_token(hdr.get("queue_token") if hdr else "").get("kind") if hdr else None
    if hdr is None:
        return V("work_dispatched", INCONCLUSIVE, "NO_CYCLE_IN_WINDOW", evidence,
                 "no cycle ran in the window, so whether work existed is unknown. Not green.")
    # One completeness rule, both checks: a header with no `backlog=` field is INCOMPLETE, and
    # `queue_readable` already refuses to grade it. Accepting the absence as zero here let
    # `work_dispatched` — "the one that matters most" — assert that a fleet's non-dispatch was
    # CORRECT on evidence the module had declared incomplete.
    if pool_kind == "EMPTY" and backlog is None:
        return V("work_dispatched", INCONCLUSIVE, "HEADER_INCOMPLETE",
                 "queue=EMPTY but the header carries no `backlog=` field: %s" % hdr,
                 "an incomplete header cannot establish that the pool was genuinely empty, so "
                 "'nothing to dispatch' is not established. Not green.")
    if pool_kind == "EMPTY" and backlog == 0:
        return V("work_dispatched", PASS, "IDLE_EMPTY_POOL", evidence,
                 "nothing was dispatched because the pool was read as genuinely EMPTY — the one "
                 "shape where 'no dispatch' is the correct outcome.")
    if isinstance(pool, int) and pool >= c.pool_threshold:
        return V("work_dispatched", INCONCLUSIVE, "NO_CANDIDATES",
                 evidence + "\npool=%d (above threshold %d) but backlog=0" % (pool, c.pool_threshold),
                 "the pool held %d issue(s) and the backlog was empty, so there was nothing to "
                 "dispatch: the defect is upstream (queue_readable owns it), and 'no work "
                 "dispatched' cannot be graded from here. Not green." % pool)
    return V("work_dispatched", INCONCLUSIVE, "NO_WORK_EVIDENCE", evidence,
             "no dispatch line and no positive evidence that dispatchable work existed. Not green.")


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Checks 4 & 5 — PRs created / merged
# ════════════════════════════════════════════════════════════════════════════════════════════════


def _activity(f):
    """Did the fleet have work in hand? Used to decide whether 'no PR' is a FAILURE or an IDLE."""
    events = f.get("log_events") or {}
    hdr = newest(events.get("headers"))
    if not hdr:
        return False, "no cycle header in the parsed log tail"
    backlog = hdr.get("backlog")
    pool = parse_queue_token(hdr.get("queue_token")).get("pool")
    busy = bool((isinstance(backlog, int) and backlog > 0) or (isinstance(pool, int) and pool > 0))
    return busy, "backlog=%s pool=%s" % (backlog, pool)


def _gh_surface_txt(gh):
    src = gh.get("source")
    if not src:
        return "surface: none (gh unreadable)"
    note = gh.get("fallback_reason")
    return "surface: %s%s" % (src, (" (%s)" % note) if note else "")


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
    ev = ("PRs created in the last %.2gh: %s\n(open=%s merged=%s in the same window)\n"
          "last created: %s\n%s"
          % (win / 3600.0, n, gh.get("prs_merged_in_window"), gh.get("open_pr_count"),
             gh.get("last_created") or "none in the query window", _gh_surface_txt(gh)))
    if isinstance(n, int) and n > 0:
        return V("pr_created", PASS, "CREATED", ev)
    busy, why = _activity(f)
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
    ev = ("PRs MERGED in the last %.2gh: %s\nopen PRs now: %s\nlast merged: %s\n%s"
          % (win / 3600.0, n, open_n, gh.get("last_merged") or "none in the query window",
             _gh_surface_txt(gh)))
    if isinstance(n, int) and n > 0:
        return V("pr_merged", PASS, "MERGED", ev)
    busy, why = _activity(f)
    if isinstance(open_n, int) and open_n > 0:
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
    pids = pane.get("pids") or []
    cmd = pane.get("cmd") or "cmux-tui"
    if pane.get("ok") is False:
        return V("pane_daemon", INCONCLUSIVE, "PROCESS_TABLE_UNREADABLE",
                 "process table read failed: %s" % (pane.get("error") or "?"),
                 "whether the pane daemon is alive could not be established. Not green.")
    if not pids:
        return V("pane_daemon", FAIL, "DAEMON_ABSENT",
                 "processes matching %s: 0\n%s" % (cmd, _pane_protection_txt(pane)),
                 "no pane daemon: every lane's surface goes with it, and an OOM kill leaves the "
                 "supervising unit reading 'active'.")

    adj = [p.get("oom_score_adj") for p in pids]
    known = [a for a in adj if a is not None]
    pid_txt = ", ".join(str(p.get("pid")) for p in pids)
    prot_txt = _pane_protection_txt(pane)

    if not pane.get("protection_supported", False):
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
    protected = [a for a in known if a < 0]
    if not protected:
        return V("pane_daemon", FAIL, "PROTECTION_ABSENT",
                 "%d live %s process(es) (pid %s)\noom_score_adj: %s\n%s"
                 % (len(pids), cmd, pid_txt, adj, prot_txt),
                 "the daemon is alive and NOT OOM-protected (oom_score_adj > 0 means the kernel "
                 "may kill it first). Being alive today is not protection.")
    if len(protected) < len(pids):
        return V("pane_daemon", FAIL, "PROTECTION_PARTIAL",
                 "%d live %s process(es) (pid %s)\noom_score_adj: %s\nprotected: %d of %d\n%s"
                 % (len(pids), cmd, pid_txt, adj, len(protected), len(pids), prot_txt),
                 "some pane-daemon processes are unprotected; the unprotected one is the one an "
                 "OOM kill takes.")
    return V("pane_daemon", PASS, "ALIVE_PROTECTED",
             "%d live %s process(es) (pid %s)\noom_score_adj: %s\n%s"
             % (len(pids), cmd, pid_txt, adj, prot_txt))


def _pane_protection_txt(pane):
    if pane.get("protection_supported"):
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

    if disk.get("ok"):
        gb = (disk.get("avail_bytes") or 0) / float(1 << 30)
        lines.append("disk: %.1f GiB free (%.1f%% used) on %s — floor %.1f GiB"
                     % (gb, disk.get("used_pct") if disk.get("used_pct") is not None else -1,
                        disk.get("mount") or "/", c.disk_floor_gb))
        if gb < c.disk_floor_gb:
            bad.append("disk %.1f GiB < %.1f GiB" % (gb, c.disk_floor_gb))
    else:
        lines.append("disk: UNREADABLE (%s)" % (disk.get("error") or "?"))
        unknown.append("disk")

    if mem.get("ok"):
        mb = mem.get("avail_mb") or 0
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

GREEN_CONCLUSIONS = ("SUCCESS", "NEUTRAL", "SKIPPED", "CANCELLED", "STALE")


def rollup_is_green(rollup):
    """The repo-wide GREEN rule, applied to one PR's rollup: non-empty, and nothing red.

    Polarity, not vocabulary: `success`/`neutral`/`skipped` are green, `cancelled`/`stale` are
    non-red, and EVERY OTHER CONCLUSION — including one GitHub has not documented and a null one —
    is RED. A missing check is not a green check: an EMPTY rollup returns False.
    """
    if not rollup:
        return False
    for chk in rollup:
        if not isinstance(chk, dict):
            return False
        concl = chk.get("conclusion")
        if concl is None:
            # queued / in progress / no conclusion yet: NOT green (in flight is not a pass)
            return False
        if str(concl).upper() not in GREEN_CONCLUSIONS:
            return False
    return True


MERGEABLE_STATES = ("CLEAN",)

# The states a REST/GraphQL response can carry that mean "mergeability is NOT KNOWN YET" (GraphQL
# documents `mergeStateStatus: UNKNOWN` while it computes). Such a PR must be reported as UNPROBED so
# it reaches PARTIAL_POPULATION — dropping it silently is how a green PR with an expired lander
# disappears.
MERGEABILITY_UNKNOWN = ("", "UNKNOWN")


def check_landers(f, c):
    gh = f.get("github") or {}
    if gh.get("ok") is not True:
        return V("landers", INCONCLUSIVE, "GH_UNREADABLE",
                 "gh: %s" % (gh.get("error") or "call failed"),
                 "the open-PR population could not be read, so 'every green PR has an armed "
                 "lander' is not established. Not green.")

    prs = gh.get("open_prs") or []
    events = f.get("log_events") or {}
    armed_log = set(r.get("pr") for r in events.get("armed") or [] if r.get("pr") is not None)
    railed_log = set(r.get("pr") for r in events.get("railed") or [] if r.get("pr") is not None)

    candidates, unprobed = [], []
    for pr in prs:
        if pr.get("draft"):
            continue
        if not pr.get("probed", True):
            unprobed.append(pr.get("number"))
            continue
        if pr.get("merge_state_status") not in MERGEABLE_STATES:
            continue
        if not pr.get("checks_green"):
            continue
        if pr.get("review_decision") not in (None, "", "APPROVED"):
            continue
        candidates.append(pr)

    if not candidates:
        if unprobed:
            return V("landers", INCONCLUSIVE, "PARTIAL_POPULATION",
                     "open PRs: %d, unprobed (beyond the probe bound): %s\n%s\n%s"
                     % (len(prs), unprobed, _gh_surface_txt(gh), _prs_brief(prs)),
                     "%d open PR(s) could not be probed (the REST fallback is bounded), so "
                     "'every green PR has an armed lander' is not established over the whole "
                     "population. Not green." % len(unprobed))
        return V("landers", PASS, "NOTHING_GREEN",
                 "open PRs: %d\nnone is green+mergeable (no lander is expected)\n%s\n%s"
                 % (len(prs), _gh_surface_txt(gh), _prs_brief(prs)),
                 "")

    expired, missing, ok = [], [], []
    for pr in candidates:
        n = pr.get("number")
        if pr.get("auto_armed"):
            ok.append(n)
        elif n in railed_log:
            ok.append(n)          # rail mode: `--auto` is deliberately NOT armed by design
        elif n in armed_log:
            # The LOG says a lander was armed and GitHub says it is not armed now. That is the
            # silent expiry: the lander went away and nothing said so.
            expired.append(n)
        else:
            missing.append(n)

    ev = ["open PRs: %d, green+mergeable: %d" % (len(prs), len(candidates)),
          _gh_surface_txt(gh),
          "armed/railed: %s" % (sorted(ok) if ok else "none")]
    if unprobed:
        # ⛔ NOT a footnote. `_collect_rest` stops probing at `rest_probe_max`, and a failed
        # check-runs call also yields probed=False, so on a box where GraphQL is exhausted this is
        # 15 of 40 PRs. A probed-and-armed PR used to end the question: the verdict was PASS and the
        # unread PRs appeared NOWHERE — a false green on the one check that exists to catch a lander
        # expiring on a PR nobody looked at.
        ev.append("UNPROBED (never read, beyond the probe bound): %s" % unprobed)
    if expired:
        ev.append("ARMED IN THE LOG, NOT ARMED IN GITHUB (expired): %s" % sorted(expired))
    if missing:
        ev.append("NEVER ARMED AND NOT RAILED: %s" % sorted(missing))
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
                 "nor a rail-mode PENDING decision." % len(missing))
    if unprobed:
        return V("landers", INCONCLUSIVE, "PARTIAL_POPULATION", evidence,
                 "%d of %d non-draft open PR(s) could not be probed, so 'every green PR has an "
                 "armed lander' is established for the rest but NOT for the whole population. "
                 "Not green." % (len(unprobed), len(prs)))
    return V("landers", PASS, "LANDERS_ARMED", evidence)


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


def exit_code(verdicts):
    if any(v.status == FAIL for v in verdicts):
        return 1
    if any(v.status == INCONCLUSIVE for v in verdicts):
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

    def __init__(self, path, box):
        self.path = path
        self.box = box
        self.data = {"version": STATE_VERSION, "boxes": {}}
        try:
            with open(path) as fh:
                d = json.load(fh)
            if isinstance(d, dict) and isinstance(d.get("boxes"), dict):
                self.data = d
        except Exception:
            pass
        self.data.setdefault("boxes", {})
        self.data["boxes"].setdefault(box, {"notified": {}})
        self.data["boxes"][box].setdefault("notified", {})

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
        amb = self.data["boxes"][self.box].get("ambiguous") or {}
        for k in list(amb):
            if k.split("|")[0] == check:
                del amb[k]

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
        # An AMBIGUOUS marker must be pruned the same way, or the suppression outlives the shape it
        # was recorded for: an attempt for NOT_DISPATCHED that may have landed would keep suppressing
        # that shape FOREVER, so the next time the fleet returns to it the alert is never sent — the
        # silence this method exists to prevent, one state further on.
        amb = self.data["boxes"][self.box].get("ambiguous") or {}
        for k in list(amb):
            if k != keep and k.split("|")[0] == check:
                del amb[k]

    def save(self):
        d = os.path.dirname(os.path.abspath(self.path)) or "."
        try:
            os.makedirs(d, exist_ok=True)
        except Exception:
            pass
        tmp = self.path + ".tmp.%d" % os.getpid()
        with open(tmp, "w") as fh:
            json.dump(self.data, fh, indent=1, sort_keys=True)
        os.replace(tmp, self.path)


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


def plan_notifications(verdicts, state, box, obs_iso, now):
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
        if v.key in state.notified or state.is_ambiguous(v.key):
            suppressed.append(v)
            continue
        to_send.append((v, compose_message(v, verdicts, box, obs_iso)))
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
                4: "AMBIGUOUS (sent, not consumed)", 5: "AMBIGUOUS (send state not established)"}

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
    if rc in (2, 3):
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
    rc, out = sh.sh("bash %s %s %s %s" % (_q(script), _q(ws), _q(label), _q(path)), timeout=300)
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
    return {"ok": snap.get("ok", True),
            "pids": [p.get("pid") for p in snap.get("pids") or []],
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


class Machine(object):
    """Command boundary. Local = a bash subshell; remote = `cmux cloud exec <box> -- sh -c …`.

    Every probe is a POSIX shell command so ONE implementation serves both, and `--box` cannot
    drift into a second set of predicates. `remote` is recorded so the respawn path can refuse
    honestly instead of pretending to restart a job it cannot reach, and so the SEND path can use
    a LOCAL runner: `cmux workspace list`/`safe-send.sh` must run where the cmux socket is.
    """

    MAX_TIMEOUT = 900

    def __init__(self, box=None, timeout=120):
        self.box = box or "local"
        self.remote = bool(box and box not in ("local", "localhost", "."))
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
        if rc != 0:
            return {"ok": False, "pids": [], "error": (out or "").strip()[:300]}
        rows, near = pick_controller_pids(out, self.controller_paths)
        return {"ok": True, "pids": rows, "near_misses": near[:8],
                "scoped_to": list(self.controller_paths or [])}

    def snapshot_pane(self):
        rc, out = self.sh("ps -Ao pid=,command= 2>&1")
        if rc != 0:
            return {"ok": False, "error": out.strip()[:300], "pids": []}
        pids = []
        for line in out.splitlines():
            line = line.strip()
            if "cmux-tui" not in line or "ps -Ao" in line:
                continue
            pid = line.split(None, 1)[0]
            if not pid.isdigit():
                continue
            adj = self.oom_score_adj(pid)
            pids.append({"pid": int(pid), "oom_score_adj": adj})
        probe_rc, probe = self.sh("test -r /proc/self/oom_score_adj && echo yes || echo no")
        supported = (probe.strip().endswith("yes"))
        rec = {"ok": True, "pids": pids, "cmd": "cmux-tui",
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

    def log_age(self):
        log, _ = self.facts_probe_log()
        return log.get("age_s")

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
            rec["age_s"] = max(0.0, time.time() - mtime)
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
        tail_lines = tail.splitlines() if rc2 == 0 else []
        return ({"path": path, "exists": True, "mtime": mtime,
                 "mtime_iso": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(mtime)),
                 "age_s": max(0.0, now - mtime)}, tail_lines, None)

    def read_file(self, path):
        rc, out = self.sh("cat %s 2>&1" % _q(path))
        if rc != 0:
            return None, out.strip()[:200]
        return out, None

    def launchd_state(self, label):
        rc, out = self.sh("launchctl list 2>&1")
        if rc != 0:
            return {"loaded": None, "pid": None, "label": label, "error": out.strip()[:200]}
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
            "else vm_stat | awk '/page size of/{ps=$8} /Pages free/{free=$3} "
            "/Pages inactive/{inact=$3} /Pages speculative/{spec=$3} "
            "END{gsub(/\\./,\"\",ps); gsub(/\\./,\"\",free); gsub(/\\./,\"\",inact); "
            "gsub(/\\./,\"\",spec); printf \"darwin %d\\n\", (free+inact+spec)*ps/1024/1024}'; fi 2>&1")
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
    rc, txt = _run_gh([gh, "pr", "list", "--repo", repo, "--state", "merged", "--limit", "100",
                       "--json", "number,mergedAt,createdAt"])
    if rc != 0:
        errors.append("graphql: gh pr list --state merged rc=%s: %s" % (rc, _one_line(txt)))
        return None
    merged = _json_list(txt)
    if merged is None:
        errors.append("graphql: gh pr list --state merged returned unparseable JSON")
        return None
    out = _gh_empty()
    out["source"] = "graphql"
    _fill_counts(out, open_prs, merged, cfg, now)
    out["open_prs"] = [
        {
            "number": p.get("number"),
            "merge_state_status": (p.get("mergeStateStatus") or "").strip().upper(),
            "auto_armed": p.get("autoMergeRequest") is not None,
            "draft": bool(p.get("isDraft")),
            "checks_green": rollup_is_green(p.get("statusCheckRollup")),
            "review_decision": p.get("reviewDecision"),
            "probed": (p.get("mergeStateStatus") or "").strip().upper() not in MERGEABILITY_UNKNOWN,
        }
        for p in open_prs
    ]
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

    out = _gh_empty()
    out["source"] = "rest"
    _fill_counts(out, open_raw, merged, cfg, now)

    probe_max = int(getattr(cfg, "rest_probe_max", 25) or 25)
    rows, unprobed, detail_errors = [], 0, []
    for i, p in enumerate(open_raw):
        num = p.get("number")
        row = {"number": num, "draft": bool(p.get("draft")),
               "auto_armed": p.get("auto_merge") is not None,
               "merge_state_status": None, "checks_green": None, "review_decision": None,
               "probed": False}
        if row["draft"] or i >= probe_max:
            unprobed += 1
            rows.append(row)
            continue
        rc, txt = _run_gh([gh, "api", "repos/%s/pulls/%s" % (repo, num)])
        det = _json_obj(txt) if rc == 0 else None
        if det is None:
            detail_errors.append("pulls/%s rc=%s" % (num, rc))
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
                row["review_decision"] = None   # REST exposes no reviewDecision; the required
                #                                  review-gate CHECK is in the rollup above, which is
                #                                  what the merge rail actually keys on.
            else:
                detail_errors.append("commits/%s/check-runs rc=%s" % (sha[:8], rc2))
        row["probed"] = (row["checks_green"] is not None
                         and row["merge_state_status"] not in MERGEABILITY_UNKNOWN)
        rows.append(row)
    out["open_prs"] = rows
    out["unprobed"] = unprobed
    if detail_errors:
        out["detail_errors"] = detail_errors[:5]
    out["ok"] = True
    return out


def _fill_counts(out, open_prs, merged, cfg, now):
    win = cfg.pr_window_s
    merged_ts = [t for t in (parse_github_ts(p.get("mergedAt") or p.get("merged_at"))
                             for p in merged) if t]
    out["prs_merged_in_window"] = len([t for t in merged_ts if now - t <= win])
    out["last_merged"] = _iso(max(merged_ts)) if merged_ts else None
    created_ts = [t for t in (parse_github_ts(p.get("createdAt") or p.get("created_at"))
                              for p in list(merged) + list(open_prs)) if t]
    out["prs_created_in_window"] = len([t for t in created_ts if now - t <= win])
    out["last_created"] = _iso(max(created_ts)) if created_ts else None
    out["open_pr_count"] = len(open_prs)


def _one_line(txt):
    txt = (txt or "").strip()
    return txt.splitlines()[0][:300] if txt else ""


def _json_list(txt):
    try:
        d = json.loads(txt or "[]")
        return d if isinstance(d, list) else None
    except ValueError:
        return None


def _json_obj(txt):
    try:
        d = json.loads(txt or "{}")
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
        hb["age_s"] = max(0.0, now - int(txt)) if hb["ok"] else None
        if not hb["ok"]:
            hb["error"] = "unparseable heartbeat: %r" % hb_raw[:80]
    facts["heartbeat"] = hb

    qs_raw, qs_err = machine.read_file(os.path.join(cfg.o_dir, "state", "queue-state"))
    qs = {"path": os.path.join(cfg.o_dir, "state", "queue-state")}
    if qs_raw is None:
        qs["ok"] = False
        qs["error"] = qs_err
        qs["raw"] = None
    else:
        qs["ok"] = True
        qs["raw"] = qs_raw.strip()[:120]
        m = re.search(r"\b(\d{9,})\b", qs_raw)
        qs["age_s"] = max(0.0, now - int(m.group(1))) if m else None
    facts["queue_state"] = qs

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
    return d


def run_static(paths, only=None):
    """Evaluate fixtures and compare against each fixture's own `_expect`. Returns (rows, mismatches)."""
    rows, mism = [], []
    for path in paths:
        fx = load_fixture(path)
        cfg = cfg_from_dict(fx.get("config"))
        verdicts = evaluate(fx["facts"], cfg, only=only)
        expect = fx.get("_expect") or {}
        got = dict((v.name, v.status) for v in verdicts)
        for name, want in expect.items():
            if name not in got:
                # ⛔ A fixture that names a check which does not exist asserts NOTHING, and the old
                # `continue` then printed "every fixture matched" and exited 0 — a no-op gate that
                # reports the opposite of what it did. (Also covers `--only`, which excludes checks
                # from `got`.) An unknown name is a mismatch; a known name excluded by --only is
                # reported as SKIPPED, loudly, by the caller.
                mism.append((path, name, want, "UNKNOWN_CHECK" if name not in PREDICATES
                             else "NOT_EVALUATED", None))
                continue
            if got[name] != want:
                mism.append((path, name, want, got[name],
                             [v for v in verdicts if v.name == name][0]))
        rows.append((path, fx.get("name") or os.path.basename(path), fx.get("note") or "",
                     verdicts, expect))
    return rows, mism


def fixture_paths(paths, fixtures_dir):
    out = []
    for p in paths or []:
        out.append(p)
    if fixtures_dir:
        out.extend(sorted(glob.glob(os.path.join(fixtures_dir, "*.json"))))
    return out


def default_fixtures_dir():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", "..", "tests", "fixtures", "outcome-canary"))


# ════════════════════════════════════════════════════════════════════════════════════════════════
# Rendering
# ════════════════════════════════════════════════════════════════════════════════════════════════

MARK = {PASS: "✅ PASS", FAIL: "⛔ FAIL", INCONCLUSIVE: "⚠️  INCONCLUSIVE"}


def render(verdicts, cfg, header):
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
    code = exit_code(verdicts)
    lines.append("")
    lines.append("summary: %d PASS · %d FAIL · %d INCONCLUSIVE → exit %d"
                 % (counts.get(PASS, 0), counts.get(FAIL, 0), counts.get(INCONCLUSIVE, 0), code))
    return "\n".join(lines)


# ════════════════════════════════════════════════════════════════════════════════════════════════
# CLI
# ════════════════════════════════════════════════════════════════════════════════════════════════


def build_parser():
    ap = argparse.ArgumentParser(
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
    ap.add_argument("--controller-ws", default=None, help="controller workspace UUID (live send)")
    ap.add_argument("--controller-name", default=None, help="substring of the controller workspace NAME")
    ap.add_argument("--state", dest="state_path", default=None, help="notification state file/dir")
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
    ap.add_argument("--no-notify", action="store_true", help="evaluate only; compose no messages")
    ap.add_argument("--no-respawn", action="store_true", help="never attempt a respawn")
    ap.add_argument("--verbose", action="store_true")
    return ap


def cfg_from_args(a):
    o_dir = os.path.abspath(os.path.expanduser(
        a.o_dir or os.environ.get("O") or os.path.join(os.path.expanduser("~"), "orchestrator")))
    kw = {
        "o_dir": o_dir,
        "log_path": os.path.join(o_dir, "logs", "orch-loop.log"),
        "box": a.box or "local",
        "state_path": a.state_path or default_state_path(),
        "controller_ws": a.controller_ws,
    }
    if a.repo:
        kw["repo"] = a.repo
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
    now = time.time()

    if a.static:
        paths = fixture_paths(a.fixture, a.fixtures_dir if a.fixtures_dir is not None
                              else (None if a.fixture else default_fixtures_dir()))
        if not paths:
            print("outcome-canary: no fixtures found (pass --fixture or --fixtures-dir)", file=sys.stderr)
            return 3
        rows, mism = run_static(paths, only=only)
        if a.json:
            print(json.dumps({"mode": "static", "fixtures": [
                {"path": p, "name": n, "note": note,
                 "verdicts": [v.as_json() for v in vs], "expect": ex}
                for p, n, note, vs, ex in rows], "mismatches": [
                    {"path": p, "check": c, "expected": w, "got": g,
                     "variant": (vv.variant if vv is not None else None),
                     "evidence": (vv.evidence if vv is not None else None)}
                    for p, c, w, g, vv in mism]}, indent=1))
        else:
            for p, n, note, vs, ex in rows:
                hdr = "fixture %s (%s)%s" % (n, os.path.basename(p), (" — " + note) if note else "")
                print(render(vs, cfg_from_dict({}), hdr))
                print()
            if mism:
                print("⛔ %d predicate mismatch(es) against the fixture's own _expect:" % len(mism))
                for p, c, w, g, vv in mism:
                    print("   %s: %s expected %s, got %s%s"
                          % (os.path.basename(p), c, w, g,
                             (" (%s)" % vv.variant) if vv is not None else ""))
                    if vv is not None:
                        print("      evidence: %s" % str(vv.evidence).replace("\n", " | ")[:300])
            else:
                if only:
                    print("✅ every fixture matched its declared _expect (note: --only %s means the "
                          "other %d check(s) per fixture were NOT asserted)"
                          % (",".join(only), len(CHECK_ORDER) - len(only)))
                else:
                    print("✅ every fixture matched its declared _expect")
        return 1 if mism else 0

    # ── live ────────────────────────────────────────────────────────────────────────────────
    cfg = cfg_from_args(a)
    machine = Machine(None if cfg.box in (None, "local") else cfg.box)
    machine.log_path = cfg.log_path
    machine.tail_lines = 6000
    machine.controller_paths = cfg.controller_paths()
    if a.facts:
        # INJECTED FACTS through the LIVE path. The predicates are the same ones `--static` runs;
        # what this adds is the SIGNAL machinery (compose → de-duplicate → send/respawn) so that
        # machinery can be executed against a known-bad shape with no box and no clock.
        try:
            with open(a.facts) as fh:
                inj = json.load(fh)
            facts = inj.get("facts", inj)
        except Exception as exc:
            print("outcome-canary: cannot read --facts %s: %s" % (a.facts, exc), file=sys.stderr)
            return 3
    else:
        facts = collect_live(cfg, machine=machine, now=now, skip=skip)
    verdicts = evaluate(facts, cfg, only=only)
    code = exit_code(verdicts)

    obs_iso = _iso(now)
    header = ("outcome canary — LIVE box=%s repo=%s  %s\n"
              "window=%.0fs  pr-window=%.0fs  mem-floor=%.0fMiB  disk-floor=%.0fGiB  pool-threshold=%d"
              % (cfg.box, cfg.repo or "(unknown — pass --repo)", obs_iso, cfg.window_s,
                 cfg.pr_window_s, cfg.mem_floor_mb, cfg.disk_floor_gb, cfg.pool_threshold))

    reported = {"respawn": None, "sent": [], "suppressed": [], "not_delivered": []}

    # (a) respawn — ONLY when the controller is genuinely absent
    ctrl = [v for v in verdicts if v.name == "controller_cycling"]
    ctrl_v = ctrl[0] if ctrl else None
    if ctrl_v is not None and ctrl_v.variant in RESPAWN_TRIGGERS and not a.no_respawn:
        rr = attempt_respawn(ctrl_v, cfg, machine, dry_run=a.dry_run)
        reported["respawn"] = rr
        # Re-check after a successful respawn so the report reflects what is TRUE now.
        if rr.get("took"):
            facts2 = collect_live(cfg, machine=machine, now=time.time(), skip=skip)
            verdicts = evaluate(facts2, cfg, only=only)
            code = exit_code(verdicts)
    elif ctrl_v is not None and ctrl_v.variant in RESPAWN_TRIGGERS:
        reported["respawn"] = {"attempted": False, "took": False,
                               "detail": "suppressed by --no-respawn", "commands": []}

    # (b)+(c) notify — change-only, sanctioned path, never mid-turn
    state = None
    if not a.no_notify:
        state = State(cfg.state_path, cfg.box)
        to_send, suppressed = plan_notifications(verdicts, state, cfg.box, obs_iso, now)
        reported["suppressed"] = [v.key for v in suppressed]
        extra = None
        if reported["respawn"]:
            rr = reported["respawn"]
            extra = ["RESPAWN", "  " + (rr.get("detail") or "not attempted")]
            for argv, rc, out in rr.get("commands") or []:
                extra.append("  $ %s  → rc=%s %s" % (" ".join(argv), rc, (out or "")[:200]))
        for v, _msg in to_send:
            ws = cfg.controller_ws
            ws_why = "--controller-ws"
            if not ws:
                # cmux discovery and the send must run on the LOCAL box: the socket lives here,
                # and a remote `cmux workspace list` would answer for a different fleet.
                ws, ws_why = find_controller_workspace(machine.local(), a.controller_name)
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

    if a.json:
        print(json.dumps({"mode": "live", "box": cfg.box, "repo": cfg.repo,
                          "observed_at": obs_iso,
                          "config": cfg.as_json(),
                          "verdicts": [v.as_json() for v in verdicts],
                          "exit": code,
                          "signal": {
                              "respawn": reported["respawn"],
                              "sent": reported["sent"],
                              "suppressed": reported["suppressed"],
                              "not_delivered": reported["not_delivered"],
                              "state_error": reported.get("state_error"),
                          }}, indent=1))
        return code

    print(render(verdicts, cfg, header))
    if reported["respawn"]:
        rr = reported["respawn"]
        print("\nrespawn: %s" % (rr.get("detail") or "not attempted"))
        for argv, rc, out in rr.get("commands") or []:
            print("  $ %s  → rc=%s %s" % (" ".join(argv), rc, (out or "")[:200]))
    if reported["sent"]:
        print("\nnotified (delivered): %s" % ", ".join(
            "%s/%s" % (s["check"], s["variant"]) for s in reported["sent"]))
    if reported["suppressed"]:
        print("\nsuppressed (state unchanged, already notified): %s"
              % ", ".join(reported["suppressed"]))
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
