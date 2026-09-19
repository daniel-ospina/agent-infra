#!/usr/bin/env python3
"""tools/fleet/lane_liveness.py — the SCHEDULED lane-liveness report (#1178 unit 3).

WHY THIS EXISTS
---------------
``tools/fleet/liveness.py`` (units 1-2) is a **pull** tool: a verdict exists only
when somebody asks. If the orchestrator is dead, nothing asks — and the owner
requirement is exactly *"a way to check which lanes are stuck, independent of the
orchestrator being dead."* This driver makes the check **scheduled and
self-delivering**: it runs under launchd, produces a verdict for every lane, and
escalates a ``dead`` lane to a deduped GitHub issue with no orchestrator alive
and nobody pulling.

It is a DRIVER, not a second opinion: every per-lane verdict comes from
``liveness.gather`` + ``liveness.evaluate`` — the SAME predicate the kill-path
reaper sources (``scripts/lib/pid-identity.sh``). This file never calls
``os.kill`` and never decides liveness itself; adding a second probe here would
re-create the "two contracts for one safety rule" defect #1178 exists to remove.

WHAT A "LANE" IS (the enumeration decision — the whole point)
-------------------------------------------------------------
A lane is **a cmux-surface lane the fleet has a session record for** — the
durable, human-visible unit the fleet reports on. The population is the durable
cmux HOOK STORE (``~/.cmuxterm/pi-hook-sessions.json``), one lane per
``workspaceId``: the newest NON-CHILD record for that workspace supplies the
lane's session id and its recorded incarnation (``pid`` +
``pidStartSeconds``).

    hook store (durable)                     session JSONL        process table
    ├─ ws 02657288 → sid 01a0a05f, pid …     the transcript       the probe CLI
    ├─ ws BF44DC37 → sid 01a093de, pid …     (growth = liveness)  (identity)
    └─ …

The population does **NOT** come from the live process table. That is the defect
being closed: every detector that builds its population from live processes makes
a dead lane *disappear*, because a lane whose process is gone is absent from that
population. The store is a file whose records OUTLIVE the process (measured: a
real pi was killed in a real workspace and its record survived), so a dead lane
stays ENUMERATED and can be reported as dead. Union of sources, each for one
question: the **hook store** for *which lanes exist and what incarnation they
had*, the **session JSONL** for *whether it is still growing*, and the **shared
probe CLI** for *whether that incarnation is still alive*.

TWO ENUMERATION TRAPS, both measured on this machine (not guessed)
------------------------------------------------------------------
1. **The ``cmux`` CLI is unusable from launchd.** ``cmux workspace list`` fails
   with ``Access denied - only processes started inside cmux can connect`` when
   the caller is not a cmux-spawned process — verified by actually running the
   installed launchd job (exit 2, the message in the durable log). Anything the
   timed job reads at runtime must therefore be a FILE: the hook store, the
   session JSONLs, and ``ps``. (The reviewed reaper takes the same route: it
   reads the store file and never calls the ``cmux`` CLI.)
2. **Task children share the parent's ``workspaceId``/``surfaceId``.** 2139 of
   5101 task-session children have store records on their parent's workspace, so
   "newest record for this workspace" silently picks a CHILD's incarnation and
   would verdict the child, not the lane. Children are excluded by their
   transcript home: a sid with a directory under ``~/.pi/agent/task-sessions/``
   is a child. The newest NON-CHILD record per workspace is the lane.

The store also retains workspaces whose pane has since been CLOSED (measured: 8
of 34 on this host, including two superseded orchestrator workspaces). They are
still REPORTED as lanes — nothing disappears — and the recency rule below keeps
them out of the issue. A lane with no store record at all is not enumerable
(there is no session id to probe); reported as a residual in the unit report.

THE ESCALATION POLICY
---------------------
Escalate on **``dead``** only. ``wedged``/``idle``/``running-quiet``/``unknown``
are REPORTED (named, with evidence) but do not file an issue. ``dead`` is
unambiguous and is the state that was structurally invisible. This was
originally forced by a classifier defect (#1254): a merely-idle interactive
REPL read ``wedged`` (``jsonl-frozen``) 47 minutes after a completed turn,
because ``wedged`` fired on any frozen transcript. ``liveness.py`` now requires
POSITIVE evidence of an open turn, so a turn-ended lane reports
``running-quiet`` (``turn-ended``) however long it rests short of the 24h
retirement proof, and ``wedged`` means what it says. The escalation policy
still stays ``dead``-only — a
reporting fix is not a licence to file issues on a diagnostic state.

Exit codes (mirroring ``scripts/fleet-cost-weekly.sh``):
    0  clean  — no dead lane
    1  escalation — at least one dead lane (issue filed unless --dry-run)
    2  env/usage error — nothing was decided; no issue is ever filed

TCC CONSTRAINT, END TO END (#427/#432)
--------------------------------------
launchd cannot read ``~/Documents``. Every path this job touches at runtime is
therefore outside that wall, and the plist pins the probe library explicitly:
  * the driver + ``liveness.py``  → ``~/.pi/agent/tools/fleet/``   (farmed)
  * the probe library             → ``~/.pi/agent/scripts/lib/``  (farmed, unit 2)
  * store / sessions / log        → ``~/.cmuxterm``, ``~/.pi/agent``
``liveness.lib_path()`` resolves ``<here>/../../scripts/lib/pid-identity.sh``;
farmed at ``~/.pi/agent/tools/fleet/`` that is exactly
``~/.pi/agent/scripts/lib/pid-identity.sh`` — the farm layout is what makes the
relative resolution land inside the wall. The plist also sets
``PI_PID_IDENTITY_LIB`` so the resolution is auditable rather than incidental.
There is no ``cmux`` socket call to fail (see trap 1) and no ``~/Documents`` read
anywhere on the runtime path.

Env seams (tests + tuning; production uses the defaults):
    GH_BIN                gh binary (default: gh; stubbed in tests)
    FLEET_REPO            github slug (default: daniel-ospina/agent-infra)
    LANE_LIVENESS_LOG     durable log (default: ~/.pi/agent/state/lane-liveness.log)
    LANE_LIVENESS_STORE   hook store (default: ~/.cmuxterm/pi-hook-sessions.json)
    LANE_LIVENESS_SESSIONS_DIR   session JSONL root (default: ~/.pi/agent/sessions)
    LANE_LIVENESS_TASK_SESSIONS  task-child root (default: ~/.pi/agent/task-sessions)
    PI_PID_IDENTITY_LIB   probe CLI (default: liveness.lib_path())
"""

from __future__ import annotations

import argparse
import atexit
import datetime
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

try:  # the farm promise: lane_liveness.py and liveness.py land side by side.
    import liveness  # noqa: E402
except ImportError as _exc:  # pragma: no cover - env dependent
    sys.stderr.write(
        "lane-liveness: FATAL: cannot import the liveness classifier next to this "
        "driver (%s). The pi-bootstrap farm must copy tools/fleet/liveness.py and "
        "tools/fleet/lane_liveness.py together.\n" % _exc
    )
    raise SystemExit(2)

HOME = os.path.expanduser("~")
DEFAULT_STORE = os.path.join(HOME, ".cmuxterm", "pi-hook-sessions.json")
DEFAULT_SESSIONS_DIR = os.path.join(HOME, ".pi", "agent", "sessions")
DEFAULT_TASK_SESSIONS = os.path.join(HOME, ".pi", "agent", "task-sessions")
DEFAULT_LOG = os.path.join(HOME, ".pi", "agent", "state", "lane-liveness.log")
DEFAULT_REPO = "daniel-ospina/agent-infra"
# cmux persists its live layout here; used to keep CLOSED workspaces out of the
# lane population (a retired pane is not a lane). A FILE, on purpose — see
# open_workspace_ids().
DEFAULT_CMUX_STATE = os.path.join(
    HOME, "Library", "Application Support", "cmux", "session-com.cmuxterm.app.json"
)

# The dedup title marker. Deliberately a compound hyphenated token plus a word,
# QUOTED as a literal phrase: unquoted, GitHub tokenizes `lane-liveness` and the
# search can match an unrelated issue that happens to contain both words (the
# documented fleet-cost collision trap), burying the escalation. No other fleet
# job's title contains the substring `lane-liveness`.
TITLE_PREFIX = "lane-liveness escalation"
DEDUP_QUERY = '"lane-liveness escalation" in:title'

# `dead` only. A reporting fix is not a licence to escalate a diagnostic state:
# `wedged` requires an open-turn proof, but it is still a judgment about a
# lane that has a live holder, and `dead` (every incarnation gone) remains the
# only unambiguous, structurally-invisible state.
ESCALATE_STATES = frozenset({"dead"})

# A dead lane escalates only while it is still an ACTIVE lane: its last transcript
# write (or, with no transcript, its record's own `updatedAt`) must be inside the
# REAPER's idle proof — `REAP_IDLE_HOURS` = 24h (`liveness.IDLE_MS`; policy:
# docs/ops/pi-idle-repl-reaper-policy.md). A lane quiet for longer than that was
# already a reaper candidate, so its process going away is retirement, not a
# stuck lane — MEASURED, not assumed: on this host an open pane from 11 days ago
# (`Login & Onboarding`) and one quiet 30h (`API keys table`) both read `dead`
# with their panes still open; escalating those every pass is the noise class
# #1178 exists to remove. The lane is still REPORTED as dead — nothing
# disappears — only the ISSUE is withheld.
DEAD_ESCALATE_WINDOW_MS = liveness.IDLE_MS

# Report state order: worst first, so a human reading the log sees the signal.
STATE_ORDER = ("dead", "wedged", "idle", "running-quiet", "unknown")

LOG_CAP_BYTES = 512 * 1024


class EnvError(RuntimeError):
    """A missing/unreadable input: exit 2, never an escalation."""


# One `ps` READ per pass, not one per probe (#1030-adjacent: a forked probe per
# candidate is correct identity-wise but pays a full `ps -axo` each time). The
# shared library forks one read per probe; within a single report pass those
# reads are ONE snapshot — exactly what the reviewed reaper does (a single table
# per pass) — so this wrapper runs the real `ps` once and replays its bytes.
# It is not a second opinion and fabricates nothing: a failed read is NOT cached
# (the library's exit-2 UNKNOWN semantics survive), and an explicit PS_BIN from
# the environment (tests, tuning) always wins. Measured effect: a pass that took
# >6 min under fleet load (≈78 `ps -axo` forks contending with other agents'
# poll loops) drops to one fork.
PS_CACHE_WRAPPER = """#!/bin/bash
# lane-liveness `ps` cache. Invoked by scripts/lib/pid-identity.sh as
# `\"$PS_BIN\" -axo <the pinned field list>`; the field list is identical on every
# call within a pass, so caching the bytes is a snapshot, not a guess.
cache="${LANE_LIVENESS_PS_CACHE:?}"
if [ -s "$cache" ]; then exec cat "$cache"; fi
ps_bin="${LANE_LIVENESS_PS_REAL:-/bin/ps}"
out="$("$ps_bin" "$@")" || exit $?
printf '%s' "$out" > "$cache"
printf '%s' "$out"
"""


def install_ps_cache() -> None:
    """Point the identity library's PS_BIN at a one-read-per-pass cache.

    Skipped when PS_BIN is already set (an explicit override wins) or when
    LANE_LIVENESS_PS_CACHE=0. The wrapper lives under $TMPDIR — outside the
    ~/Documents TCC wall, so launchd can execute it (#427).
    """
    if os.environ.get("PS_BIN") or os.environ.get("LANE_LIVENESS_PS_CACHE") == "0":
        return
    try:
        d = tempfile.mkdtemp(prefix="lane-liv-ps-")
        path = os.path.join(d, "ps")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(PS_CACHE_WRAPPER)
        os.chmod(path, 0o755)
    except OSError:
        return  # a cache we cannot install must never fail the report
    atexit.register(shutil.rmtree, d, ignore_errors=True)
    os.environ["PS_BIN"] = path
    os.environ["LANE_LIVENESS_PS_CACHE"] = os.path.join(d, "ps.cache")


@dataclass(frozen=True)
class Lane:
    workspace: str
    name: str
    sid: str
    record: Dict[str, object]


# ── the durable sources ─────────────────────────────────────────────────
def open_workspace_ids(path: str = DEFAULT_CMUX_STATE):
    """The workspace UUIDs cmux currently has OPEN, or ``None`` if unavailable.

    The ``cmux`` CLI is NOT usable from launchd: ``cmux workspace list`` fails
    with ``Access denied - only processes started inside cmux can connect``
    (measured by running the installed job). cmux persists its live layout to
    this JSON file instead — outside the ~/Documents TCC wall, no socket, no
    secret. Any read/parse/shape failure returns ``None`` so the caller falls
    back to the store's own workspace set and SAYS SO, never to an empty
    population. This filter is what keeps a deliberately retired pane (a
    superseded orchestrator / decision-relay workspace, closed at a cutover) out
    of the issue: measured, four such workspaces had records younger than the
    reaper's 24h idle proof and would otherwise have been escalated as dead.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    ids = set()
    for window in data.get("windows") or []:
        if not isinstance(window, dict):
            continue
        manager = window.get("tabManager")
        if not isinstance(manager, dict):
            continue
        for ws in manager.get("workspaces") or []:
            if isinstance(ws, dict) and isinstance(ws.get("workspaceId"), str):
                ids.add(ws["workspaceId"])
    return ids or None


def _lane_label(rec: dict, workspace: str) -> str:
    """A human label for the lane: the cwd's last path component."""
    """A human label for the lane: the cwd's last path component."""
    cwd = rec.get("cwd")
    if isinstance(cwd, str) and cwd.strip("/"):
        base = os.path.basename(cwd.rstrip("/"))
        if base:
            return base
    return workspace[:8]


def child_sids(task_sessions_dir: str) -> frozenset:
    """The sids that are TASK CHILDREN (their transcript home is task-sessions).

    A task child's hook record carries its parent's ``workspaceId``/``surfaceId``
    (measured: 2139 of 5101 children), so excluding them is what stops "newest
    record for this workspace" from verdicting a child instead of the lane. A
    missing root means "no children on this host", not an error.
    """
    try:
        names = os.listdir(task_sessions_dir)
    except OSError:
        return frozenset()
    return frozenset(n for n in names if os.path.isdir(os.path.join(task_sessions_dir, n)))


def _stamp(rec: dict) -> float:
    for key in ("updatedAt", "startedAt"):
        val = rec.get(key)
        if isinstance(val, (int, float)):
            return float(val)
    return 0.0


def enumerate_lanes(sessions: Dict[str, dict], children) -> List[Lane]:
    """One lane per workspace: its newest NON-CHILD record.

    The population is the durable store, so it is unaffected by whether the pi
    process is still alive — a dead lane stays enumerated (the whole point).
    """
    best: Dict[str, Tuple[float, str, dict]] = {}
    for sid, rec in sessions.items():
        if not isinstance(rec, dict) or sid in children:
            continue
        workspace = rec.get("workspaceId")
        if not isinstance(workspace, str) or not workspace:
            continue
        stamp = _stamp(rec)
        cur = best.get(workspace)
        if cur is None or stamp > cur[0]:
            best[workspace] = (stamp, sid, rec)
    lanes = [Lane(workspace=ws, name=_lane_label(rec, ws), sid=sid, record=rec)
             for ws, (_stampv, sid, rec) in best.items()]
    lanes.sort(key=lambda l: (l.name.lower(), l.workspace))
    return lanes


# ── the one liveness opinion (never re-implemented here) ────────────────
def verdict_for(lane: Lane, *, store_path: str, sessions_dir: str, lib: Optional[str], now_ms: int):
    """``(verdict, evidence)`` — the verdict from the ONE shared predicate."""
    ev = liveness.gather(
        lane.sid, store_path=store_path, sessions_dir=sessions_dir, lib=lib, now_ms=now_ms,
    )
    return liveness.evaluate(ev), ev


def last_activity_age_ms(ev: "liveness.Evidence") -> Optional[int]:
    """How long since this lane last did anything.

    The transcript mtime is the activity truth; with no transcript (a session
    that never wrote one) the record's own ``updatedAt`` stands in. ``None``
    means the age could not be established.
    """
    if ev.jsonl_age_ms is not None:
        return ev.jsonl_age_ms
    stamp = ev.record.updated_at if ev.record is not None else None
    if isinstance(stamp, (int, float)) and stamp > 0:
        return max(0, int(ev.now_ms - stamp * 1000))
    return None


def escalatable(verdict, ev, *, window_ms: int = DEAD_ESCALATE_WINDOW_MS) -> bool:
    """Should this verdict FILE an issue? (state ∧ still-an-active-lane)

    Never a second liveness opinion: the state is ``liveness.evaluate``'s, and
    the recency is the reaper's own idle proof applied to the evidence the
    classifier already gathered.
    """
    if verdict.state not in ESCALATE_STATES:
        return False
    age = last_activity_age_ms(ev)
    if age is None:
        return False  # unknown recency: report it, never file on a guess
    return age <= window_ms


# ── durable log ─────────────────────────────────────────────────────────
def append_log(path: str, text: str) -> None:
    """Append to the durable log, capping it (never an unbounded /tmp capture)."""
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(text if text.endswith("\n") else text + "\n")
        if os.path.getsize(path) > LOG_CAP_BYTES:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                data = fh.read()
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("… [log truncated to the last %d KiB]\n" % (LOG_CAP_BYTES // 1024))
                fh.write(data[-LOG_CAP_BYTES:])
    except OSError as exc:  # pragma: no cover - env dependent
        sys.stderr.write("lane-liveness: WARN: cannot write log %s: %s\n" % (path, exc))


# ── the report ──────────────────────────────────────────────────────────
def _short(uuid: str) -> str:
    return (uuid or "")[:8]


def _ts(now_ms: int) -> str:
    return datetime.datetime.fromtimestamp(now_ms / 1000.0, datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def render_report(
    ts: str,
    lanes: Sequence[Tuple[Lane, "liveness.Verdict", "liveness.Evidence"]],
    *,
    host: str,
    escalate_states,
    window_ms: int = DEAD_ESCALATE_WINDOW_MS,
    population_source: str = "store",
) -> str:
    counts = {state: 0 for state in STATE_ORDER}
    for _lane, v, _ev in lanes:
        counts[v.state] = counts.get(v.state, 0) + 1
    summary = " · ".join("%d %s" % (counts[s], s) for s in STATE_ORDER if counts.get(s))
    lines: List[str] = []
    lines.append("## Lane liveness — %s" % ts)
    lines.append("")
    lines.append(
        "Scheduled lane-liveness report (#1178) on `%s`. **%d lane(s):** %s. "
        "Population: %s." % (host, len(lanes), summary or "none", population_source)
    )
    lines.append("")
    lines.append(
        "Escalation policy: **%s**, and only while the lane is still active "
        "(last activity within %.0fh — the reaper's own idle proof). "
        "`wedged` requires positive evidence of an OPEN turn (a pending tool "
        "call, or no assistant reply) frozen past the stream bound; a lane whose "
        "last turn ended reads `running-quiet`/`turn-ended` however long it "
        "rests short of the 24h retirement proof, so only a lane whose every "
        "incarnation is gone files an issue." % (", ".join(sorted(escalate_states)), window_ms / 3_600_000.0)
    )
    lines.append("")
    lines.append("| lane | workspace | session | state | reason | evidence |")
    lines.append("|---|---|---|---|---|---|")
    ordered = sorted(lanes, key=lambda lv: (STATE_ORDER.index(lv[1].state)
                                            if lv[1].state in STATE_ORDER else 99, lv[0].name.lower()))
    for lane, v, _ev in ordered:
        # Both halves of the evidence stay visible: the open turn the verdict
        # named (#1254) AND the holder/witness row it was decided from.
        parts = [v.detail] if v.detail else []
        if v.witnesses:
            parts.append(", ".join(v.witnesses))
        elif v.holder_pid:
            parts.append("holder=%d" % v.holder_pid)
        evidence = ", ".join(parts) or "—"
        lines.append("| %s | `%s` | `%s` | **%s** | `%s` | %s |"
                     % (lane.name, _short(lane.workspace), lane.sid[:8], v.state, v.reason, evidence))

    dead = [(lane, v, ev) for lane, v, ev in ordered if v.state in escalate_states]
    active = [(lane, v, ev) for lane, v, ev in dead
              if escalatable(v, ev, window_ms=window_ms)]
    stale = [(lane, v, ev) for lane, v, ev in dead if (lane, v, ev) not in active]
    if active:
        lines.append("")
        lines.append("### ⚠️ %d active dead lane(s) — escalated" % len(active))
        lines.append("")
        for lane, v, _ev in active:
            lines.append(
                "- **%s** (`%s`, session `%s`): `%s` — %s"
                % (lane.name, _short(lane.workspace), lane.sid, v.state,
                   ", ".join(v.witnesses) or v.detail or v.reason)
            )
        lines.append("")
        lines.append(
            "A dead lane is the one state no live-process-derived detector can show: "
            "its process is gone, so it drops out of every population built from `ps`. "
            "Confirm with `cmux read-screen --workspace %s` before acting." % active[0][0].workspace
        )
    if stale:
        lines.append("")
        lines.append(
            "%d dead lane(s) withheld from escalation — quiet longer than the "
            "reaper's %.0fh idle proof (retirement, not a stuck lane; still "
            "listed above): %s."
            % (len(stale), window_ms / 3_600_000.0, ", ".join(l.name for l, _v, _e in stale))
        )
    if not dead:
        lines.append("")
        lines.append("No dead lane: nothing to escalate.")
    return "\n".join(lines)


# ── escalation (mirrors scripts/fleet-cost-weekly.sh) ────────────────────
def escalate(repo: str, title: str, body: str, gh_bin: str) -> str:
    """One OPEN `lane-liveness escalation` issue → comment; else create.

    The query is a QUOTED literal phrase so it cannot tokenize into words that
    match an unrelated title (the documented fleet-cost collision trap).
    """
    try:
        proc = subprocess.run(
            [gh_bin, "issue", "list", "--repo", repo, "--state", "open",
             "--search", DEDUP_QUERY, "--json", "number", "--jq", ".[0].number"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, check=False,
        )
        existing = proc.stdout.decode("utf-8", "replace").strip().strip("[]").strip()
    except (OSError, subprocess.SubprocessError):
        existing = ""
    if existing and existing != "null":
        try:
            proc = subprocess.run(
                [gh_bin, "issue", "comment", "--repo", repo, existing, "--body", body],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=60, check=False,
            )
            if proc.returncode == 0:
                return "commented on existing issue #%s" % existing
        except (OSError, subprocess.SubprocessError):
            pass
        return "WARN gh comment failed for issue #%s" % existing
    try:
        proc = subprocess.run(
            [gh_bin, "issue", "create", "--repo", repo, "--title", title, "--body", body],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, check=False,
        )
        url = proc.stdout.decode("utf-8", "replace").strip()
    except (OSError, subprocess.SubprocessError):
        url = ""
    if url:
        return "opened issue: %s" % url
    return "WARN gh issue create failed for %s" % repo


# ── main ────────────────────────────────────────────────────────────────
def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        prog="lane_liveness.py",
        description="Scheduled lane-liveness report (#1178): verdicts for every open "
                    "cmux lane, including lanes whose process is gone.",
    )
    ap.add_argument("--dry-run", action="store_true",
                    help="print the report and the would-be escalation; never call gh")
    ap.add_argument("--store", default=os.environ.get("LANE_LIVENESS_STORE", DEFAULT_STORE))
    ap.add_argument("--sessions-dir",
                    default=os.environ.get("LANE_LIVENESS_SESSIONS_DIR", DEFAULT_SESSIONS_DIR))
    ap.add_argument("--task-sessions",
                    default=os.environ.get("LANE_LIVENESS_TASK_SESSIONS", DEFAULT_TASK_SESSIONS))
    ap.add_argument("--log", default=os.environ.get("LANE_LIVENESS_LOG", DEFAULT_LOG))
    ap.add_argument("--repo", default=os.environ.get("FLEET_REPO", DEFAULT_REPO))
    ap.add_argument("--cmux-state",
                    default=os.environ.get("LANE_LIVENESS_CMUX_STATE", DEFAULT_CMUX_STATE),
                    help="cmux's persisted layout — the open-workspace filter")
    ap.add_argument("--gh-bin", default=os.environ.get("GH_BIN", "gh"))
    ap.add_argument("--json", action="store_true", help="also print the raw verdicts as JSON")
    ap.add_argument("--now", type=int, default=None,
                    help="pin the clock (epoch ms) — tests only")
    return ap.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ns = parse_args(argv)
    install_ps_cache()
    now_ms = ns.now if ns.now is not None else int(datetime.datetime.now().timestamp() * 1000)
    ts = _ts(now_ms)
    host = socket.gethostname().split(".")[0]

    def log(text: str) -> None:
        append_log(ns.log, text)

    try:
        store_ok, sessions = liveness.load_store(ns.store)
        if not store_ok:
            raise EnvError("hook store unreadable or shape-drifted: %s" % ns.store)
        if not sessions:
            raise EnvError("hook store has no session records: %s" % ns.store)
        if not os.path.isdir(ns.sessions_dir):
            raise EnvError("sessions dir missing: %s" % ns.sessions_dir)
        children = child_sids(ns.task_sessions)
        lanes = enumerate_lanes(sessions, children)
        open_ids = open_workspace_ids(ns.cmux_state)
        if open_ids is not None:
            lanes = [l for l in lanes if l.workspace in open_ids]
        population_source = ("open workspaces from cmux's persisted layout"
                             if open_ids is not None else
                             "store fallback (cmux layout unreadable — closed workspaces may appear)")
        if not lanes:
            raise EnvError(
                "no lane records in %s: the store may be shape-drifted or all %d "
                "record(s) are task children" % (ns.store, len(sessions))
            )
        lib = os.environ.get("PI_PID_IDENTITY_LIB") or liveness.lib_path()
        pairs: List[Tuple[Lane, "liveness.Verdict", "liveness.Evidence"]] = []
        for lane in lanes:
            v, ev = verdict_for(
                lane, store_path=ns.store, sessions_dir=ns.sessions_dir, lib=lib, now_ms=now_ms,
            )
            pairs.append((lane, v, ev))
    except EnvError as exc:
        line = "%s ERROR: %s — no verdict, no issue" % (ts, exc)
        print(line, file=sys.stderr)
        log(line)
        return 2

    body = render_report(ts, pairs, host=host, escalate_states=ESCALATE_STATES,
                         population_source=population_source)
    dead = [(lane, v, ev) for lane, v, ev in pairs if escalatable(v, ev)]
    counts = {}
    for _lane, v, _ev in pairs:
        counts[v.state] = counts.get(v.state, 0) + 1
    summary = "lanes=%d %s" % (len(pairs), " ".join("%s=%d" % (s, counts[s])
                                                   for s in STATE_ORDER if counts.get(s)))

    if ns.json:
        print(json.dumps({
            "lanes": [{"lane": lane.name, "workspace": lane.workspace, "sid": lane.sid,
                       "escalatable": escalatable(v, ev), **v.to_dict()}
                      for lane, v, ev in pairs],
            "counts": counts,
        }, sort_keys=True))

    if not dead:
        line = "%s PASS %s — no escalatable dead lane" % (ts, summary)
        print(line)
        print(body)
        log(line + "\n" + body + "\n")
        return 0

    title = "%s: %d dead lane(s) (%s)" % (TITLE_PREFIX, len(dead),
                                          ", ".join(l.name for l, _v, _e in dead[:4]))
    if ns.dry_run:
        line = "%s [dry-run] would file: %s (%s)" % (ts, title, summary)
        print(line)
        print(body)
        log(line + "\n" + body + "\n")
        return 1

    outcome = escalate(ns.repo, title, body, ns.gh_bin)
    line = "%s → %s (%s)" % (ts, outcome, summary)
    print(line)
    print(body)
    log(line + "\n" + body + "\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
