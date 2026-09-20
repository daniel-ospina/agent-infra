#!/usr/bin/env python3
"""tools/fleet/liveness.py — the fleet's ONE session-liveness verdict (#1178).

WHY THIS EXISTS
---------------
Three detectors reported the fleet's lanes and **none of them could say
``dead``**: ``map-sessions.py`` reads session files and never a process;
``stall-sweep.py`` and ``stale-stuck.py`` both derive their population from
live cmux processes, so a lane whose process is gone does not read ``idle`` or
``unknown`` — it **disappears from the report**. Absence is the one failure mode
a report cannot show, and it cost a five-hour loss. The mirror failure is a
false positive: a working child was declared ``wedged`` with
``toolsInFlight=1`` / ``toolAgeMaxMs ≈ 1.19M ms`` while it was still working.

So the verdict lives here, once, as a pure function over evidence:

    dead | running-quiet | wedged | idle | unknown

``running-quiet`` is the fail-closed state — quiet is never a stall. ``unknown``
is a NAMED abstention, never a dumping ground. ``dead`` is reachable ONLY from
positive evidence that every incarnation is gone.

``wedged`` needs ONE condition more than a frozen transcript (#1254). A session
file stops growing for two opposite reasons: the lane is **at a prompt**, or it
is **stuck mid-turn** — and "quiet for 20 minutes" is the fleet's normal
resting state, so firing ``wedged`` on it makes the state read as "not written
to lately", not "stuck". ``wedged`` therefore requires POSITIVE evidence of an
OPEN turn, read from the transcript's last message-bearing entry:

* an assistant message CARRYING tool calls whose ``stopReason`` is not one
  under which pi discards them (``error`` / ``aborted``) — on ``length`` pi
  **fails** the truncated message's calls (``failToolCallsFromTruncatedMessage``,
  pi-agent-core ``dist/agent-loop.js``) and then CONTINUES the turn, so a
  ``length`` message with calls is still awaiting the turn's next step;
* an assistant message whose ``stopReason`` is ``toolUse``;
* a ``toolResult`` with no assistant reply after it;
* a user prompt with no assistant reply after it.

A transcript whose last turn ended with a TERMINAL ``stopReason`` — ``stop`` or
``length`` on a message carrying NO tool calls, or ``error`` / ``aborted`` with or
without calls (they end the agent run outright) — is RESTING: however long it has
been quiet short of the retirement
proof it reads ``running-quiet``, never ``wedged``; the ``reason`` field names
which path
returned that state. Terminality is an EXPLICIT set
(``TERMINAL_STOP_REASONS``), never a fall-through: on a CALL-FREE message a
``stopReason`` in NEITHER that set nor ``NON_TERMINAL_STOP_REASONS`` — including
one pi has not emitted yet — ABSTAINS with ``turn-unknown:<value>`` rather than
asserting the lane is resting (#1272). A
message CARRYING calls is decided first by the call-carrying rule above, which
keeps ``length``+calls and ``stop``+calls OPEN. ``turn-state-unknown`` (a tail
that cannot be read as a turn boundary) and ``tail-after-compaction`` (a summary
line pi writes *between* turns) are ABSTENTIONS — absence of evidence is not a
stall. Reasons this rule introduces, none of them escalating:

    turn-ended                       the last turn ended; the lane awaits input
    no-turn-yet                      no turn boundary in the transcript yet
    turn-open:pending-tool-call      an assistant toolCall with no result
    turn-open:awaiting-assistant     a toolResult with no assistant reply
    turn-open:awaiting-response      a user prompt with no assistant reply
    turn-open:no-terminal-stop       the last assistant message has no stopReason
    turn-unknown:<stopReason>        an UNRECOGNIZED stopReason; an abstention
    tail-after-compaction            a compaction entry is the last entry
    turn-state-unknown               the tail could not be read as a turn

ORDERING IS THE SAFETY PROPERTY
-------------------------------
Identity is decided FIRST (it is the only source of ``dead``), and every "still
working" signal is a VETO against ``wedged``, never a reason to escalate. This
is the direction ``docs/ops/pi-idle-repl-reaper-policy.md`` already mandates
("no proof ⇒ not idle ⇒ never kill") applied to the diagnostic.

THE CONTRACT, AS FORMAL CONDITIONS (each re-derived, not paraphrased)
---------------------------------------------------------------------
* **``wedged`` requires a POSITIVELY OPEN turn** (#1254): frozen past the
  watchdog's stream bound **and** the transcript's last message-bearing entry
  shows an unfinished turn. A turn-ended transcript is ``running-quiet`` however
  long it rests (short of the retirement proof); a turn that cannot be
  classified is ``unknown``. This gates ``wedged`` ONLY — ``dead`` is decided
  from fenced-holder identity BEFORE the ladder and no turn state may reach it.
* **dead** ⟺ the candidate set is NON-EMPTY **and** every candidate was
  positively OBSERVED absent or a zombie in a fresh ``ps`` read **and** the
  session JSONL did not grow inside the window. An empty candidate set is
  ``unknown (no-holder-record)`` — "every candidate is gone" is vacuously true
  of nothing, and a live lane with a session file and no store record must never
  read ``dead`` (#1178 C4).
* **off-fence is an ABSTENTION, never a death witness** (#1178 C1). The ±3s
  fence exists because second-granularity rounding differs by ~1s; its purpose
  is to make an identity *uncertainty* fail safe. A live process whose recorded
  ``pidStartSeconds`` is stale, wrong, or unparseable is ``unknown`` — this is
  the same direction ``scripts/pi-reap-idle.sh`` takes (a stale sibling "no
  vote"; ``SKIP incarnation-unmatched`` when nothing matches).
* **growth is positive liveness evidence** (#1178 C6): a JSONL that grew inside
  the window ⇒ ``running-quiet``, even with no fenced holder, naming the
  un-fenced writer. JSONL growth is therefore decided BEFORE identity, so a
  growing lane can never read ``dead``.
* **``ps`` unreadable ≠ ``ps`` empty** (#1178 C3): a failed read is ``unknown``,
  never ``dead``. The probe CLI (``scripts/lib/pid-identity.sh``) encodes this as
  exit 1 (positively absent/zombie) vs exit 2 (unknown/unreadable).
* **a live writer with no store record is a candidate** (#1178 C2): a pi process
  whose argv names the session (``pi --session <id>``, the documented resume
  form) holds that session whether or not the store records it. Without this,
  "the record's incarnation is gone" is silently equated with "the lane is
  dead".
* **the hung-tool veto expires at the WATCHDOG's own per-shape bound** (#1178
  C5, from ``extensions/builtin-tools/index.ts``). See ``tool_veto_expired``.
* **the CPU-flat exemption is the watchdog's** (#1178 C8): ``CPU_LIVENESS_TOOL_NAMES``
  is ``{"bash"}`` and ``task`` is deliberately absent, so a nested sub-agent
  waiting on a provider response is legitimately CPU-flat and must not read
  ``wedged``.
* **the input-consumption veto gates ``idle``/``wedged`` ONLY — never ``dead``**
  (#1178 C9). Its freshness bound is #947's (``REAP_STUCK_HOURS``, default 72h).

Sources are cited inline. This module INVENTS no bound: every constant below is
a copy of a reviewed constant, with its file and line, and the CLI consumes the
already-computed tick fields (``cpu_advanced`` / ``cpu_stall_ms``) rather than
re-deriving CPU attribution.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Sequence, Tuple

__all__ = [
    "STATES",
    "STREAM_STALL_MS",
    "CPU_STALL_MS",
    "HEARTBEAT_TIMEOUT_MS",
    "HARD_CAP_MS",
    "RECORD_VETO_MS",
    "IDLE_MS",
    "CPU_LIVENESS_TOOL_NAMES",
    "Candidate",
    "Tool",
    "Record",
    "Turn",
    "Evidence",
    "Verdict",
    "CALL_DISCARDING_STOP_REASONS",
    "TERMINAL_STOP_REASONS",
    "tool_stall_ms",
    "cpu_attributable",
    "tool_veto_expired",
    "record_vetoes",
    "is_dead_evidence",
    "observed_from_probe",
    "turn_from_entry",
    "turn_from_jsonl",
    "evaluate",
    "collect_candidates",
    "gather",
    "lib_path",
    "load_store",
    "jsonl_state",
]

STATES = ("dead", "running-quiet", "wedged", "idle", "unknown")

# #1254: the turn boundary is read from the transcript's TAIL — bounded, so a
# multi-MB session file is never read whole (the boundary is always at the
# end). The window grows only when a transcript carries no message entry in the
# first read (a shape pi does not write; measured over 426 live session files,
# every one had a message entry inside the first 256 KiB).
TURN_TAIL_BYTES = 262_144
TURN_TAIL_CAP_BYTES = 16 * 1024 * 1024
# The stop reasons under which an assistant turn CONTINUES even with no
# parseable tool call: `toolUse` awaits a tool result. `stop` / `length` /
# `error` / `aborted` end the turn WHEN THE MESSAGE CARRIES NO TOOL CALL; when
# it does carry calls, `CALL_DISCARDING_STOP_REASONS` decides.
NON_TERMINAL_STOP_REASONS = frozenset({"toolUse"})
# #1254 cycle-1 P0: a message CARRYING tool calls is OPEN unless its stop reason
# is one under which pi DISCARDS those calls. Measured over the 426 live session
# files in `~/.pi/agent/sessions` — assistant messages carrying toolCalls, and
# whether a matching toolResult follows:
#     stopReason  withToolCalls  resultFollows  unanswered
#     toolUse        147,466       147,431         35
#     error              115             0        115   <- calls discarded
#     length              78            78          0   <- calls FAILED, so OPEN
#     aborted             16             0         16   <- calls discarded
# `resultFollows` is NOT `executed`: on `length` pi FAILS the truncated
# message's calls (`failToolCallsFromTruncatedMessage`, pi-agent-core
# `dist/agent-loop.js:136-138`) — all 78 results after a `length`+calls message
# carry `isError: true` ("Tool call ... was not executed") — and the loop
# CONTINUES the turn. `length` is NOT terminal here. The earlier 78/78 count
# measured that a RESULT was written, not that the call RAN; a count of results
# is not evidence of work. Reading a message by its stopReason alone made a
# still-running turn read `turn-ended` — the #1254 fail-open shape, aimed at
# the classifier itself.
CALL_DISCARDING_STOP_REASONS = frozenset({"error", "aborted"})
# #1272: the stop reasons on a CALL-FREE message under which pi ENDS the turn.
# `stop` and `length` end a completed turn; `error` and `aborted` END THE AGENT
# RUN outright — pi's loop returns before any tool batch
# (`pi-agent-core/dist/agent-loop.js:124-128`) — so `error`/`aborted` are
# terminal with or without calls, while `stop` and `length` are terminal only on
# a call-free message: with calls the call-carrying rule above decides, and it
# keeps both OPEN. The set is EXPLICIT so that `turn-ended` is a
# DECISION, never the fall-through for every stop reason the code has never
# seen: `turn-ended` is RESTING — unescalatable and never `wedged` — so a
# default that lands there inverts the module's own principle (`wedged` needs
# POSITIVE evidence of an open turn) and reads a genuinely suspended lane as
# merely quiet. On a CALL-FREE message a reason outside this set ABSTAINS
# (`turn-unknown:<value>`); with calls, the call-carrying rule above decides
# first, so an unrecognized reason carrying calls is an OPEN turn, not an
# abstention.
# Measured over 7,820 transcripts / 384,657 assistant messages: the only
# stopReason values that occur are exactly these four and `toolUse`, so the
# abstention is LATENT today (0 cases) — what is fixed is the DEFAULT's
# direction, not a live misclassification. The values pi's contract also names —
# `pending` (pi-ai's in-flight placeholder) and `deferred` (the harness runtime
# settles it as `deferred.suspended`) — are deliberately NOT terminal: pi has
# neither ended the turn nor closed the run, so the classifier must not claim it
# is resting (#1272).
TERMINAL_STOP_REASONS = frozenset({"stop", "length", "error", "aborted"})
# The message roles that carry a turn boundary; every other entry type
# (compaction / model_change / thinking_level_change / session / custom) is
# skipped when scanning back for the last boundary.
TURN_MESSAGE_ROLES = frozenset({"assistant", "user", "toolResult"})

# ── the bounds — every one a copy of a reviewed constant, never invented ──
# S: the in-flight-tool silence bound. `DEFAULT_STREAM_STALL_MS`,
# extensions/builtin-tools/index.ts:1545. VERBATIM and NEVER load-rescaled
# (docs/ops/load-policy.md §6; `getStreamStallMs()` index.ts:1612-1625 has no
# load term). #1178 C5 withdraws any load-scaling rule — do not re-add it.
STREAM_STALL_MS = 1_200_000
# C: the CPU-stall conjunct of the `tool-dead` clause. `DEFAULT_CPU_STALL_MS`,
# index.ts:1848.
CPU_STALL_MS = 1_800_000
# T: the heartbeat timeout, `max(60s, TASK_HEARTBEAT_TIMEOUT_MS || 1_800_000)`,
# index.ts:3133.
HEARTBEAT_TIMEOUT_MS = 1_800_000
# `DEFAULT_HARD_CAP_MS`, index.ts:1780 (6h) — the base of the tool-age backstop.
HARD_CAP_MS = 21_600_000
# `TASK_TOOL_STALL_FRACTION`, index.ts:1592 — the backstop fraction.
_TOOL_STALL_NUM, _TOOL_STALL_DEN = 2, 3
# #947 bounded-veto freshness bound: 3 × REAP_IDLE_HOURS (24h) = 72h.
# docs/ops/pi-idle-repl-reaper-policy.md:56; scripts/pi-reap-idle.sh:89-92.
RECORD_VETO_MS = 72 * 3600 * 1000
# The reaper's idle proof bound (`REAP_IDLE_HOURS` default 24h).
IDLE_MS = 24 * 3600 * 1000
# `CPU_LIVENESS_TOOL_NAMES`, extensions/task-heartbeat.ts:281 — allowlist by
# design; `task` is deliberately ABSENT (a nested sub-agent's quiet is
# legitimate), pinned by builtin-tools.test.ts test id E279a2.
CPU_LIVENESS_TOOL_NAMES = frozenset({"bash"})

HOLDER = "holder"
WITNESS_OBSERVED = frozenset({"absent", "zombie"})
# Everything else the probe can say: an ABSTENTION. `off-fence` is a live
# process whose identity could not be matched (C1); `unreadable` is a failed or
# unusable read (C3).
ABSTAIN_OBSERVED = frozenset({"off-fence", "unreadable"})


def tool_stall_ms(hard_cap_ms: int = HARD_CAP_MS) -> int:
    """`getToolStallMs()` — extensions/builtin-tools/index.ts:1690-1703.

    The AGE BACKSTOP: max(60s, floor(hardCap × 2/3)) = 4h at the 6h default.
    Derived (not the frozen 6h `DEFAULT_TOOL_STALL_MS`) so it tracks
    `TASK_HARD_CAP_MS`.
    """
    return max(60_000, int(hard_cap_ms) * _TOOL_STALL_NUM // _TOOL_STALL_DEN)


def _exceeds(value: Optional[int], bound: int) -> bool:
    """Strict `>` against a KNOWN value. An unprobed (None) age never expires a
    veto: absence of evidence must never arm an escalation."""
    return value is not None and value > bound


# ── evidence ─────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Candidate:
    """One possible holder of a session, with its probe outcome.

    ``observed`` is exactly one of ``holder`` / ``absent`` / ``zombie`` /
    ``off-fence`` / ``unreadable`` — the vocabulary of
    ``scripts/lib/pid-identity.sh``'s probe stdout, mapped by
    :func:`observed_from_probe`.

    ``kind`` is ``tag`` (a store record's pid + ``pidStartSeconds``, fenced) or
    ``argv`` (a process whose argv names the session — a direct identity claim,
    no fence needed).
    """

    pid: int
    observed: str
    kind: str = "tag"
    start_seconds: Optional[int] = None
    detail: str = ""


@dataclass
class Tool:
    """The in-flight-tool signal. Fields mirror the watchdog's tick fields.

    ``cpu_advanced`` / ``cpu_stall_ms`` are the ALREADY-COMPUTED tick fields
    (builtin-tools/index.ts:2274-2275, task-heartbeat.ts:226) — this module does
    NOT re-derive CPU attribution.
    """

    name: str = ""
    tools_in_flight: int = 0
    tool_updates: bool = False
    silence_age_ms: Optional[int] = None
    tool_age_ms: Optional[int] = None
    cpu_advanced: bool = False
    cpu_stall_ms: int = 0
    turn_active: bool = True
    hard_cap_ms: int = HARD_CAP_MS
    heartbeat_timeout_ms: int = HEARTBEAT_TIMEOUT_MS


@dataclass
class Record:
    """The cmux store record's input-consumption belief (#947).

    ``updated_at`` is the record's OWN last-write epoch (seconds). ``None`` or an
    implausible value means the stamp is unusable, which keeps the veto (fail
    closed) — an un-ageable record cannot immunise a lane forever, but it also
    cannot be read as stale.
    """

    non_idle: bool = False
    updated_at: Optional[float] = None


@dataclass(frozen=True)
class Turn:
    """The last turn's boundary, read from the session JSONL tail (#1254).

    ``stalled`` is the POSITIVE statement "the transcript shows an unfinished
    turn". It is the only thing that may license ``wedged`` when the file is
    frozen — a merely frozen file is not a stall. ``reason`` is the verdict
    reason this boundary licenses (``turn-ended`` / ``no-turn-yet`` /
    ``turn-open:*`` / ``turn-unknown:*`` / ``tail-after-compaction``); ``detail``
    names the specific open call/step where one is known, so the report says
    *why* rather than merely *that* nothing was written.

    ``abstain`` marks a boundary that licenses no disposition: a ``compaction``
    written between turns, or, on a message carrying NO tool calls, an assistant
    ``stopReason`` in neither ``TERMINAL_STOP_REASONS`` nor
    ``NON_TERMINAL_STOP_REASONS`` (#1272). Such an entry can neither license
    ``wedged`` nor be read as a finished turn, so the ladder returns ``unknown``
    naming ``reason`` — a third disposition, not a weaker ``stalled``.

    Absent evidence is NOT this object: an unreadable tail is ``None`` on
    ``Evidence.jsonl_turn``, an abstention the ladder names
    ``turn-state-unknown``.
    """

    stalled: bool
    reason: str
    detail: str = ""
    abstain: bool = False


@dataclass
class Evidence:
    """Everything a verdict may rest on. Absent fields are ``None``/defaults."""

    sid: str = ""
    ps_ok: bool = True
    store_ok: bool = True
    candidates: List[Candidate] = field(default_factory=list)
    # True/False/None — None means the JSONL's growth could not be established.
    jsonl_grew: Optional[bool] = None
    jsonl_age_ms: Optional[int] = None
    # The last turn's boundary (#1254). None = could not be established, which
    # is an ABSTENTION and never a stall.
    jsonl_turn: Optional[Turn] = None
    tool: Optional[Tool] = None
    record: Optional[Record] = None
    now_ms: int = 0
    idle_ms: int = IDLE_MS
    record_veto_ms: int = RECORD_VETO_MS


@dataclass(frozen=True)
class Verdict:
    """The state plus the evidence that decided it (requirement 3)."""

    state: str
    reason: str
    holder_pid: Optional[int] = None
    witnesses: Tuple[str, ...] = ()
    detail: str = ""

    def to_dict(self) -> Dict[str, object]:
        return {
            "state": self.state,
            "reason": self.reason,
            "holder_pid": self.holder_pid,
            "witnesses": list(self.witnesses),
            "detail": self.detail,
        }


# ── the rules ────────────────────────────────────────────────────────────
def cpu_attributable(tool: Tool) -> bool:
    """Is this tool's subtree meaningful to sample for CPU? (C8)

    ``CPU_LIVENESS_TOOL_NAMES`` is ``{"bash"}``; ``task`` is deliberately absent,
    so a nested sub-agent waiting on a provider response is legitimately
    CPU-flat and its CPU-flatness must NOT be read as evidence of a wedge.
    """
    return tool.name in CPU_LIVENESS_TOOL_NAMES


def tool_veto_expired(tool: Optional[Tool]) -> bool:
    """Would the watchdog's own clause have cut this in-flight tool by now? (C5)

    The classifier does not invent a bound: it cites the watchdog's clause table
    for the tool's SHAPE.

      * streamed, then stopped (``tool_updates``) — ``tool-silence``
        (index.ts:2605): ``effStreamAge > S`` with S = 20 min.
      * never emitted an update, but demonstrated CPU work (``cpu_advanced``) —
        ``tool-dead`` (index.ts:2680-2690) is a CONJUNCTION:
        ``toolCpuStallMs > cpuStallMs`` (:2686, 30 min) **and**
        ``effToolAge > streamStallMs`` (:2687, 20 min). 30 min binds only when
        the CPU-stall and tool-age clocks start together.
      * no output and no demonstrated CPU — the age backstop, ``tool-stall``
        (index.ts:2697-2701): ``toolStallMs`` (4h at the 6h cap) while the turn
        is ACTIVE, and ``min(toolStallMs, heartbeatTimeoutMs)`` (30 min) when it
        is NOT. The turn-inactive branch is the one v4 missed, and missing it is
        the fail-OPEN direction: the classifier would stay quiet for hours after
        the watchdog had already cut.

    While this returns False the tool is a VETO against ``wedged``; once it
    returns True the veto has EXPIRED (T9: the veto must never be forever).
    """
    if tool is None or tool.tools_in_flight <= 0:
        return False
    if tool.tool_updates:
        return _exceeds(tool.silence_age_ms, STREAM_STALL_MS)
    if cpu_attributable(tool) and tool.cpu_advanced:
        if tool.cpu_stall_ms is None or tool.cpu_stall_ms <= CPU_STALL_MS:
            return False
        return _exceeds(tool.tool_age_ms, STREAM_STALL_MS)
    if tool.turn_active:
        bound = tool_stall_ms(tool.hard_cap_ms)
    else:
        bound = min(tool_stall_ms(tool.hard_cap_ms), tool.heartbeat_timeout_ms)
    return _exceeds(tool.tool_age_ms, bound)


def record_vetoes(rec: Optional[Record], now_s: float, veto_ms: int = RECORD_VETO_MS) -> bool:
    """Does a non-idle record still VETO ``wedged``/``idle``? (#947, C9)

    ``agentLifecycle``/``runtimeStatus`` are event-driven beliefs: a lost
    turn-complete leaves ``running`` forever, so the veto is BOUNDED by the
    record's own ``updatedAt``. A record whose stamp is usable AND older than
    ``veto_ms`` is no longer current evidence. A record with NO usable stamp
    keeps the veto (fail closed — an un-ageable record can withhold a verdict,
    never cause one).
    """
    if rec is None or not rec.non_idle:
        return False
    ts = rec.updated_at
    if not isinstance(ts, (int, float)) or ts < 1_000_000_000 or ts > now_s + 86400:
        return True
    return (now_s - ts) * 1000 <= veto_ms


def is_dead_evidence(candidates: Sequence[Candidate]) -> bool:
    """The FORMAL condition for ``dead``'s identity half (C1, C4).

    NON-EMPTY **and** every candidate positively observed absent or a zombie.
    The non-emptiness is load-bearing: without it the "all()" is vacuously true
    for an empty set and a live lane with a session file but no store record
    reads ``dead`` while alive — the vacuity hole a previous revision shipped.
    """
    return bool(candidates) and all(c.observed in WITNESS_OBSERVED for c in candidates)


def observed_from_probe(rc: int, status: str) -> str:
    """Map the probe CLI's (exit code, stdout status) to a Candidate outcome.

    Exit 1 is POSITIVELY not-a-holder (absent or zombie) — the only shape that
    can witness ``dead``. Exit 2 is UNKNOWN (off-fence, unreadable, unusable
    stamp) and must never be collapsed into exit 1: a probe that did so would
    manufacture ``dead`` out of a failed ``ps`` invocation (C3).

    Any rc/status mismatch falls back to ``unreadable`` — the fail-safe
    direction.
    """
    if rc == 0 and status == "holder":
        return HOLDER
    if rc == 1 and status in ("absent", "zombie"):
        return status
    if rc == 2 and status == "off-fence":
        return "off-fence"
    if rc == 2 and status == "unknown":
        return "unreadable"
    return "unreadable"


def evaluate(ev: Evidence) -> Verdict:
    """The verdict function. Pure: no I/O, no clock, no signals."""
    # (0) Evidence availability. A failed read abstains with a NAMED reason —
    #     never a guessed verdict, and never `dead` (C3, T12).
    if not ev.ps_ok:
        return Verdict("unknown", "ps-unreadable")
    if not ev.store_ok:
        return Verdict("unknown", "store-unreadable")

    cands = list(ev.candidates)
    holders = [c for c in cands if c.observed == HOLDER]

    # (1) Growth is POSITIVE LIVENESS EVIDENCE (C6). Decided before identity so
    #     a growing lane can NEVER read `dead` (T8); it is exactly ONE verdict —
    #     `running-quiet`, naming the writer when no holder is fenced.
    if ev.jsonl_grew is True:
        if holders:
            return Verdict("running-quiet", "jsonl-grew", holder_pid=holders[0].pid)
        return Verdict("running-quiet", "jsonl-grew(writer-unidentified)")

    # (2) Identity — the ONLY source of `dead` (C1, C4).
    if not holders:
        if is_dead_evidence(cands):
            # Non-growth is required too, and it must be POSITIVELY known: an
            # unreadable JSONL cannot prove non-growth (fail safe).
            if ev.jsonl_grew is not False:
                return Verdict("unknown", "jsonl-age-unknown")
            return Verdict(
                "dead",
                "incarnations-absent",
                witnesses=tuple(f"{c.pid}:{c.observed}" for c in cands),
            )
        if not cands:
            # C4 — an empty candidate set is an abstention, exactly where the
            # reviewed kill path abstains (`SKIP incarnation-unmatched`).
            return Verdict("unknown", "no-holder-record")
        # At least one candidate ABSTAINED (off-fence / unreadable) and there is
        # no fenced holder. C1: that is an uncertainty, never a death witness.
        kinds = {c.observed for c in cands if c.observed in ABSTAIN_OBSERVED}
        reason = "off-fence" if kinds == {"off-fence"} else "incarnation-unmatched"
        return Verdict(
            "unknown",
            reason,
            detail=",".join(f"{c.pid}:{c.observed}" for c in cands),
        )

    # (3) A fenced holder exists. Every "still working" signal is a VETO against
    #     `wedged`; the state ladder only runs once they are gone.
    holder = holders[0]

    if ev.tool is not None and ev.tool.tools_in_flight > 0 and not tool_veto_expired(ev.tool):
        # Quiet is never a stall: the tool veto holds until the watchdog's own
        # per-shape bound (T9, C5) — and never for a legitimately CPU-flat
        # nested `task` (T11, C8).
        return Verdict("running-quiet", "tool-in-flight", holder_pid=holder.pid)

    # (4) The bounded input-consumption veto. It gates `idle`/`wedged` ONLY —
    #     `dead` was decided above and NO record can veto it (C9, T10).
    if record_vetoes(ev.record, ev.now_ms / 1000.0, ev.record_veto_ms):
        return Verdict("running-quiet", "record-non-idle-fresh", holder_pid=holder.pid)

    if ev.jsonl_age_ms is None:
        return Verdict("unknown", "jsonl-age-unknown", holder_pid=holder.pid)
    if ev.jsonl_age_ms > ev.idle_ms:
        return Verdict("idle", "jsonl-old", holder_pid=holder.pid)
    if ev.jsonl_age_ms <= STREAM_STALL_MS:
        return Verdict("running-quiet", "quiet-within-bound", holder_pid=holder.pid)
    # (5) Frozen past the watchdog's no-tool stream bound (`stream-stall`,
    #     index.ts:2706) and short of the idle proof. A frozen transcript has
    #     TWO causes and only one is a stall (#1254): the turn ENDED (the lane
    #     is resting at a prompt — the fleet's normal state) or it is OPEN.
    #     `wedged` requires the POSITIVE evidence of an open turn; a turn that
    #     cannot be classified is an ABSTENTION, never a stall — as is a
    #     compaction written after the last turn (pi writes it BETWEEN turns).
    turn = ev.jsonl_turn
    if turn is None:
        return Verdict("unknown", "turn-state-unknown", holder_pid=holder.pid)
    if turn.abstain:
        return Verdict("unknown", turn.reason, holder_pid=holder.pid, detail=turn.detail)
    if not turn.stalled:
        return Verdict("running-quiet", turn.reason, holder_pid=holder.pid, detail=turn.detail)
    return Verdict("wedged", turn.reason, holder_pid=holder.pid, detail=turn.detail)


# ── the process boundary (scripts/lib/pid-identity.sh) ───────────────────
def lib_path() -> str:
    env = os.environ.get("PI_PID_IDENTITY_LIB")
    if env:
        return env
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", "..", "scripts", "lib", "pid-identity.sh"))


@dataclass(frozen=True)
class ProbeResult:
    rc: int
    status: str
    detail: str = ""


def _run_lib(args: Sequence[str], *, lib: Optional[str] = None, timeout: int = 60) -> ProbeResult:
    """Run the identity CLI and parse its one-line stdout.

    A missing/unrunnable CLI is rc 2 — UNKNOWN. It must never read as absence.
    """
    cmd = ["bash", lib or lib_path()] + list(args)
    try:
        proc = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:  # pragma: no cover - env dependent
        return ProbeResult(2, "unknown", f"probe-launch-failed:{exc.__class__.__name__}")
    out = proc.stdout.decode("utf-8", "replace").strip()
    first = out.splitlines()[0].strip() if out else ""
    parts = first.split()
    status = parts[0] if parts else "unknown"
    known = {"holder", "absent", "zombie", "off-fence", "unknown"}
    if status not in known:
        status = "unknown"
    return ProbeResult(proc.returncode, status, first)


def probe_pid(pid: int, start_seconds, *, lib: Optional[str] = None) -> ProbeResult:
    """`probe <pid> <startSeconds>` — a store record's incarnation, fenced."""
    return _run_lib(["probe", str(pid), "" if start_seconds is None else str(start_seconds)], lib=lib)


def probe_argv(pid: int, *, lib: Optional[str] = None) -> ProbeResult:
    """`probe-argv <pid>` — the process itself claims the session."""
    return _run_lib(["probe-argv", str(pid)], lib=lib)


def argv_candidates(sid: str, *, lib: Optional[str] = None) -> Tuple[List[int], bool]:
    """Pids whose argv names ``sid`` in a resume form. Returns (pids, ok)."""
    res = _run_lib(["argv-candidates", str(sid)], lib=lib)
    if res.rc != 0:
        return [], False
    pids: List[int] = []
    for line in res.detail.splitlines():
        line = line.strip()
        if line.isdigit():
            pids.append(int(line))
    return pids, True


# ── store + JSONL acquisition ────────────────────────────────────────────
DEFAULT_STORE = os.path.join(os.path.expanduser("~"), ".cmuxterm", "pi-hook-sessions.json")
DEFAULT_SESSIONS_DIR = os.path.join(os.path.expanduser("~"), ".pi", "agent", "sessions")


def load_store(path: str = DEFAULT_STORE) -> Tuple[bool, Dict[str, dict]]:
    """Read the cmux store. Returns (ok, sid-keyed sessions map).

    The live shape is ``{"sessions": {sid: record}}``; a flat sid-keyed map is
    also accepted (older/alternative writers). A missing or corrupt store is
    ``(False, {})`` — the caller abstains, it never guesses.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return False, {}
    if not isinstance(data, dict):
        return False, {}
    sessions = data.get("sessions")
    if isinstance(sessions, dict):
        source = sessions
    elif data and all(isinstance(v, dict) and v.get("pid") is not None for v in data.values()):
        # A flat sid-keyed map (older/alternative writers) is only a session
        # store when every value is a record.
        source = data
    elif not data:
        return True, {}
    else:
        # Parsed as a dict but nothing in it is a session record: the shape
        # drifted. Fail closed — never read a drifted store as "zero sessions".
        return False, {}
    # pid-less entries are not records (the reaper's extractor skips them too).
    clean = {k: v for k, v in source.items() if isinstance(v, dict) and v.get("pid") is not None}
    return True, clean


def _start_of(rec: dict) -> Optional[int]:
    """The incarnation start, from either key (current records use
    ``pidStartSeconds``; ``priorProcessGenerations`` elements use
    ``startSeconds``)."""
    for key in ("pidStartSeconds", "startSeconds"):
        val = rec.get(key)
        if val is None:
            continue
        try:
            return int(val)
        except (TypeError, ValueError):
            return None
    return None


def collect_candidates(
    sid: str,
    sessions: Dict[str, dict],
    argv_pids: Sequence[int],
    probe_fn: Callable[[int, Optional[int], str], str],
) -> List[Candidate]:
    """The UNION of every candidate source for ``sid`` (C2).

    Sources: the current record, every ``priorProcessGenerations`` entry, and
    every argv-claimed pid. The union — not the newest, not the first — is what
    stops a resumed session's stale tag from calling a live lane dead.
    ``probe_fn(pid, start_seconds, kind) -> observed`` is injected so this is
    testable without a process table.
    """
    cands: List[Candidate] = []
    rec = sessions.get(sid) if isinstance(sessions, dict) else None
    if isinstance(rec, dict) and rec.get("pid") is not None:
        pid = int(rec["pid"])
        cands.append(Candidate(pid, probe_fn(pid, _start_of(rec), "tag"), "tag", _start_of(rec)))
    if isinstance(rec, dict):
        for gen in rec.get("priorProcessGenerations") or []:
            if not isinstance(gen, dict) or gen.get("pid") is None:
                continue
            pid = int(gen["pid"])
            start = _start_of(gen)
            cands.append(Candidate(pid, probe_fn(pid, start, "tag"), "tag", start))
    for pid in argv_pids or []:
        pid = int(pid)
        cands.append(Candidate(pid, probe_fn(pid, None, "argv"), "argv", None))
    return cands


def jsonl_state(path: Optional[str], now_ms: int, window_ms: int = STREAM_STALL_MS) -> Tuple[Optional[bool], Optional[int]]:
    """(grew_in_window, age_ms) from the session file's mtime.

    mtime, not the last-entry epoch: for GROWTH the direction is fail-safe (a
    touched file reads as growing, never as gone). A missing file is
    ``(False, None)`` — it cannot have grown; an unreadable one is
    ``(None, None)``.
    """
    if not path:
        return False, None
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return False, None
    except OSError:
        return None, None
    age = max(0, int(now_ms - st.st_mtime * 1000))
    return age <= window_ms, age


# ── the turn boundary (#1254) ─────────────────────────────────────────────
def _tool_call_labels(msg: dict) -> List[str]:
    """``["bash(call_00_…)", …]`` for an assistant message's toolCall items."""
    labels: List[str] = []
    for item in msg.get("content") or []:
        if not isinstance(item, dict) or item.get("type") != "toolCall":
            continue
        name = str(item.get("name") or "?")
        cid = str(item.get("id") or "")
        labels.append("%s(%s)" % (name, cid) if cid else name)
    return labels


def turn_from_entry(entry) -> Turn:
    """Classify ONE transcript entry as open, ended, unknown, or no boundary.

    Four dispositions, decided in this order of evidence:

    * OPEN (``stalled=True``) — a shape that POSITIVELY shows an unfinished
      turn. An assistant message CARRYING tool calls is open unless its
      ``stopReason`` is in ``CALL_DISCARDING_STOP_REASONS``: on ``length`` pi
      FAILS those calls and CONTINUES the turn, so ``length`` + calls awaits
      the turn's next step rather than resting. This rule is decided FIRST, so a
      call-carrying message whose reason is NOT one that discards calls is OPEN
      whatever set that reason belongs to.
    * ENDED (``stalled=False``, ``abstain=False``, reason ``turn-ended``) — a
      ``stopReason`` in ``TERMINAL_STOP_REASONS`` on a message carrying no tool
      calls, **or** ``error`` / ``aborted`` (which discard their calls) on a
      message carrying calls.
    * UNKNOWN (``stalled=False``, ``abstain=True``, reason
      ``turn-unknown:<stopReason>``) — on a message carrying NO tool calls, a
      ``stopReason`` outside ``TERMINAL_STOP_REASONS``. Unrecognized is NOT
      terminal: the classifier abstains rather than asserting the lane is
      resting, which is the only fail-closed reading of a value it cannot
      classify (#1272).
    * NO BOUNDARY (``abstain=True``) — a ``compaction`` entry. pi writes it
      BETWEEN turns, so it decides neither disposition (see ``turn_from_jsonl``
      for the measurement).

    Pure and total, and the direction is deliberate: ``stalled`` is asserted
    only on a POSITIVE open-turn shape, so a shape this parser does not
    recognize can never manufacture ``wedged`` (#1254). A non-message entry that
    is NOT a compaction (``session`` / ``model_change`` /
    ``thinking_level_change`` / ``custom``) reads ``no-turn-yet``; the wired path
    (``turn_from_jsonl``) passes only message-bearing entries, so that fallback
    is reachable only when this function is called directly.
    """
    if isinstance(entry, dict) and entry.get("type") == "compaction":
        return Turn(False, "tail-after-compaction",
                    "a compaction entry is the last entry", abstain=True)
    msg = entry.get("message") if isinstance(entry, dict) else None
    if not isinstance(msg, dict):
        return Turn(False, "no-turn-yet")
    role = msg.get("role")
    if role == "assistant":
        stop = msg.get("stopReason")
        calls = _tool_call_labels(msg)
        if calls and stop not in CALL_DISCARDING_STOP_REASONS:
            return Turn(True, "turn-open:pending-tool-call",
                        "unanswered %s" % ", ".join(calls))
        if stop in NON_TERMINAL_STOP_REASONS:
            return Turn(True, "turn-open:pending-tool-call", "unanswered tool call")
        if not stop:
            return Turn(True, "turn-open:no-terminal-stop",
                        "last assistant message carries no stopReason")
        if stop in TERMINAL_STOP_REASONS:
            return Turn(False, "turn-ended", "terminal stopReason=%s" % stop)
        # #1272: the DEFAULT is the abstention, never `turn-ended`. A stop reason
        # this classifier has not seen carries no evidence the turn ended, and
        # `turn-ended` means RESTING — the fail-open direction the module forbids.
        return Turn(False, "turn-unknown:%s" % stop, abstain=True)
    if role == "toolResult":
        name = str(msg.get("toolName") or "")
        cid = str(msg.get("toolCallId") or "")
        label = ("%s(%s)" % (name, cid)) if (name and cid) else (name or cid or "tool result")
        return Turn(True, "turn-open:awaiting-assistant",
                    "%s recorded with no assistant reply after it" % label)
    if role == "user":
        return Turn(True, "turn-open:awaiting-response",
                    "user prompt with no assistant reply")
    return Turn(False, "no-turn-yet")


def _last_message_entry(path: str, limit_bytes: int = TURN_TAIL_BYTES):
    """The last message-bearing entry AND the file's actual last entry.

    Read BACKWARDS from EOF — the last turn boundary is always at the end, so a
    bounded read suffices and the file is never read whole. Every pass reaches
    EOF, so the first parseable line it meets is the file's LAST entry. Returns
    ``(message_entry, last_entry, size)``: ``message_entry`` is ``None`` when no
    message-bearing entry was found in the window (or the file could not be
    read); ``last_entry`` is ``None`` only when the window held no parseable
    entry at all. The caller abstains, it never guesses.
    """
    try:
        size = os.path.getsize(path)
    except OSError:
        return None, None, 0
    window = limit_bytes
    last_entry = None
    while True:
        read = min(size, window)
        start = size - read
        try:
            with open(path, "rb") as fh:
                if start:
                    fh.seek(start)
                blob = fh.read(read)
        except OSError:
            return None, None, size
        lines = blob.split(b"\n")
        if start:
            # The read began mid-entry: the first line is a partial record.
            lines = lines[1:]
        for raw in reversed(lines):
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw.decode("utf-8", "replace"))
            except (ValueError, UnicodeDecodeError):
                continue
            if last_entry is None:
                last_entry = entry
            msg = entry.get("message") if isinstance(entry, dict) else None
            if isinstance(msg, dict) and msg.get("role") in TURN_MESSAGE_ROLES:
                return entry, last_entry, size
        if start == 0 or window >= TURN_TAIL_CAP_BYTES:
            return None, last_entry, size
        window = min(window * 4, TURN_TAIL_CAP_BYTES)


def turn_from_jsonl(path: Optional[str]) -> Optional[Turn]:
    """Read the tail of a session JSONL and classify its last turn (#1254).

    A ``compaction`` as the LAST entry ABSTAINS (``tail-after-compaction``)
    rather than letting the message before it decide. pi writes the compaction
    BETWEEN turns and immediately starts the next call — measured over the 426
    live session files in `~/.pi/agent/sessions`: 483 compaction entries exist,
    477 are followed by a message entry, and 357 of those are an open
    ``assistant/toolUse``. A frozen transcript whose last entry is a compaction
    is therefore NOT evidence that the turn before it ended, and reading it that
    way would classify an OPEN turn as resting — the #1254 fail-open shape.

    This is a DELIBERATE, DISCLOSED UNDER-REPORT: ``unknown`` neither licenses
    ``wedged`` nor claims the lane is resting, so the cost is a lane left
    unnamed in the diagnostic band rather than one mislabelled. Revisit it if
    the population ever justifies the inference; until then a population
    statistic is not per-case evidence, and the module's principle (``wedged``
    requires positive per-case evidence of an OPEN turn) governs.

    Other trailer types (``session`` / ``model_change`` /
    ``thinking_level_change``) carry no boundary of their own and keep the
    existing behaviour: the previous message-bearing entry decides.

    ``None`` means the boundary could not be established at all — an ABSTENTION,
    never a stall. The ladder names it ``turn-state-unknown``.
    """
    if not path:
        return None
    entry, last_entry, _size = _last_message_entry(path)
    if (last_entry is not None and isinstance(last_entry, dict)
            and last_entry.get("type") == "compaction"):
        return turn_from_entry(last_entry)
    if entry is None:
        return None
    return turn_from_entry(entry)


def session_file_for(sid: str, cwd: Optional[str], sessions_dir: str = DEFAULT_SESSIONS_DIR) -> Optional[str]:
    """The session JSONL for ``sid`` (the reaper's sid-token-boundary match)."""
    enc = (cwd or "").lstrip("/").replace("/", "-")
    candidates: List[str] = []
    if enc:
        candidates.append(os.path.join(sessions_dir, "--%s--" % enc))
    candidates.append(sessions_dir)
    for d in candidates:
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for name in sorted(names):
            if not name.endswith(".jsonl"):
                continue
            stem = name[:-len(".jsonl")]
            if stem.endswith("_" + sid) or ("_" + sid + "_") in stem:
                return os.path.join(d, name)
    return None


def gather(
    sid: str,
    *,
    store_path: str = DEFAULT_STORE,
    sessions_dir: str = DEFAULT_SESSIONS_DIR,
    lib: Optional[str] = None,
    now_ms: Optional[int] = None,
) -> Evidence:
    """Acquire the evidence for ``sid`` and return it (the caller decides).

    The acquisition is deliberately a separate function from :func:`evaluate`
    so the verdict logic is testable without I/O, and so the probe boundary is
    the only process the classifier forks.
    """
    now = int(now_ms if now_ms is not None else time.time() * 1000)
    store_ok, sessions = load_store(store_path)
    rec = sessions.get(sid) if store_ok else None

    ps_ok = True
    argv_pids: List[int] = []
    if store_ok:
        argv_pids, ps_ok = argv_candidates(sid, lib=lib)

    def probe_fn(pid: int, start_seconds: Optional[int], kind: str) -> str:
        res = probe_argv(pid, lib=lib) if kind == "argv" else probe_pid(pid, start_seconds, lib=lib)
        if "ps-read-failed" in res.detail:
            nonlocal ps_ok
            ps_ok = False
        return observed_from_probe(res.rc, res.status)

    candidates = collect_candidates(sid, sessions, argv_pids, probe_fn) if store_ok else []

    cwd = rec.get("cwd") if isinstance(rec, dict) else None
    sfile = session_file_for(sid, cwd if isinstance(cwd, str) else None, sessions_dir)
    grew, age = jsonl_state(sfile, now)
    turn = turn_from_jsonl(sfile)

    tool = _tool_from_record(rec) if isinstance(rec, dict) else None
    record = None
    if isinstance(rec, dict):
        non_idle = not (rec.get("agentLifecycle") == "idle" and rec.get("runtimeStatus") == "idle")
        record = Record(non_idle=non_idle, updated_at=_updated_at(rec.get("updatedAt")))

    return Evidence(
        sid=sid,
        ps_ok=ps_ok,
        store_ok=store_ok,
        candidates=candidates,
        jsonl_grew=grew,
        jsonl_age_ms=age,
        jsonl_turn=turn,
        tool=tool,
        record=record,
        now_ms=now,
    )


def _updated_at(val) -> Optional[float]:
    try:
        return float(val)
    except (TypeError, ValueError):
        return None


def _tool_from_record(rec: dict) -> Optional[Tool]:
    """A store record may carry the watchdog's tick fields (task children do).

    Fleet sessions generally do not — the consumer supplies them from the ps
    child scan or a heartbeat. Absent fields stay ``None``/False, which keeps
    the tool veto in place (fail-closed: quiet is never a stall).
    """
    tif = rec.get("toolsInFlight")
    if not tif:
        return None
    return Tool(
        name=str(rec.get("toolName") or ""),
        tools_in_flight=int(tif),
        tool_updates=bool(rec.get("toolUpdates")),
        silence_age_ms=rec.get("streamAgeMs"),
        tool_age_ms=rec.get("toolAgeMaxMs"),
        cpu_advanced=bool(rec.get("cpuAdvanced")),
        cpu_stall_ms=int(rec.get("cpuStallMs") or 0),
        turn_active=bool(rec.get("turnActive", True)),
    )


# ── CLI (the seam a Bash diagnostic consumes) ────────────────────────────
def main(argv: Optional[Sequence[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    sid = None
    store = DEFAULT_STORE
    sessions_dir = DEFAULT_SESSIONS_DIR
    as_json = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--sid" and i + 1 < len(argv):
            sid = argv[i + 1]; i += 2; continue
        if arg == "--store" and i + 1 < len(argv):
            store = argv[i + 1]; i += 2; continue
        if arg == "--sessions-dir" and i + 1 < len(argv):
            sessions_dir = argv[i + 1]; i += 2; continue
        if arg == "--json":
            as_json = True; i += 1; continue
        print("usage: liveness.py --sid <session-id> [--store PATH] [--sessions-dir DIR] [--json]", file=sys.stderr)
        return 2
    if not sid:
        print("usage: liveness.py --sid <session-id> [--store PATH] [--sessions-dir DIR] [--json]", file=sys.stderr)
        return 2
    verdict = evaluate(gather(sid, store_path=store, sessions_dir=sessions_dir))
    if as_json:
        print(json.dumps(verdict.to_dict(), sort_keys=True))
    else:
        print("%s %s%s" % (verdict.state, verdict.reason,
                           "" if verdict.holder_pid is None else " holder=%d" % verdict.holder_pid))
    return 0 if verdict.state != "unknown" else 3


if __name__ == "__main__":
    sys.exit(main())
