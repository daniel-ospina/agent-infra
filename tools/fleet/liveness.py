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

A SECOND AXIS answers the lane that has no transcript at all (see ``LOG_STATES``
and ``docs/ops/fleet-liveness.md`` §13). An orchestrator lane runs
``pi -p --no-session``, so the five states above have nothing to read for it and
readers fell back to the LOG's mtime — which freezes while a tool call runs. The
log-lane axis publishes, from the same ``evaluate``:

    working | frozen | finished | no-verdict | dead | unknown

Its progress contract is COPIED from ``scripts/orchestrator-harness/lane-bound.sh``
(two independent signals — subtree CPU delta and output growth — and only BOTH
flat for the full window is a freeze), and its terminal states come from the
verdict line that supervisor ALREADY writes. It is an evidence field of
``evaluate``, never a second classifier: inert when ``log_read is None``, and a
``log_read`` supplied on a session query is refused by name.

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

THE REF-CLAIM REGISTRY (#1777) — WHY A LANE CAN BE LIVE AND INVISIBLE
--------------------------------------------------------------------
The fleet's lanes are enumerated from surfaces that all require a **transcript**:
the cmux hook store and the session JSONL. An orchestrator lane runs
``pi -p --no-session`` (``lane.sh`` / ``fix-one.sh`` / ``merge-one.sh``), so it
writes **no transcript** and has **no store record** — it is in NO population
this module can build. Measured (2026-10-15): ``lane_liveness.py`` reported
``lanes=22`` and the live ``fix-8721`` lane was absent, while a controller
running ``grep -l <branch> ~/.pi/agent/sessions/*/*.jsonl`` read the emptiness as
"nobody is on it" and stated a CLEAN verdict with a live writer committing to
the branch. That is the defect class: **an undeclared-coverage inference** — a
surface declares the read set it consulted, never the gaps it cannot see.

The durable, holder-authored record that DOES name such a lane is the
**ref-claim**: ``refs/claims/<pr>-<sha12>``, written by
``scripts/orchestrator-harness/claims.sh``, whose root commit's message carries
``owner=<host>:<pid>`` and ``lease_until=<digits>``. Nothing in ``tools/fleet/``
read it. This module now accepts it as ONE MORE EVIDENCE AXIS
(``Evidence.claim_read``), decided inside the existing empty-candidate branch:

* **a durable store answers *which* lanes exist; a process probe answers
  *whether that incarnation is alive*** — the split #1178 mandates. The process
table is NOT a lane population here, and a claim is never probed at all: a claim
records no process start to fence against (``probe <pid> ""`` → rc 2
``unusable-start-seconds``) and ``probe-argv`` returns ``holder`` for any live
pid, so a presence-only probe would be a SECOND identity rule.
* **every claim verdict is ``unknown``, with one of the six named reasons in
  ``CLAIM_REASONS``** — ``claims-unreadable`` / ``no-claim-visible`` /
  ``claim-owner-unparseable`` / ``claim-held`` / ``holder-on-foreign-box`` /
  ``claim-holder-unverifiable``. ``claim-held`` asserts **ownership** liveness
  only (the declared lease window, read exactly as ``claims.sh``'s
  ``claim_acquire`` and ``orch-loop.sh``'s ``claim_live`` read it) and never
  incarnation liveness. Adopting lease *renewal* would make the lease a process
  signal and would contradict the recorded decision #1709 rec 3
  (``claims.sh``: "LEASE = DATA, NOT LIVENESS") — that is a reopen, not a change
  to make here.
* **fail-closed, structurally:** an unreadable read cannot be read as an
  absence (different reason), an absence cannot be read as "free" (it abstains
  and the detail declares the gap), a FOREIGN owner's pid is never probed, and
  ``dead`` stays unreachable for a claim because ``is_dead_evidence`` requires a
  NON-EMPTY candidate set that a claim-shaped ``Evidence`` does not have.
* **the existing ladder is untouched.** The claim branch is inside
  ``if not cands:`` — it refines the ``no-holder-record`` abstention and cannot
  override session evidence, so the ordering above still holds and a
  growing-transcript lane still reads ``running-quiet/jsonl-grew``. A pinned
  test asserts the claim logic is INERT when ``claim_read is None``.

Acquisition lives in the sibling ``claim_lanes.py`` (a driver, never a second
opinion); why a lane can be live and invisible, and the recovery procedure, are
documented in ``docs/ops/fleet-liveness.md``.

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
import stat
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable, Dict, List, Optional, Sequence, Tuple

__all__ = [
    "STATES",
    "LOG_STATES",
    "LOG_WINDOW_MS",
    "LOG_FREEZE_MS",
    "LOG_CPU_TOL_CS",
    "BOUND_VERDICTS",
    "LogRead",
    "parse_bound_verdict",
    "parse_bound_line",
    "log_lane_verdict",
    "gather_log_lane",
    "subtree_cpu_cs",
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
    "Claim",
    "ClaimRead",
    "CLAIM_REASONS",
    "claim_verdict",
    "Evidence",
    "Verdict",
    "CALL_DISCARDING_STOP_REASONS",
    "CALL_FAILED_STOP_REASONS",
    "TERMINAL_STOP_REASONS",
    "tool_stall_ms",
    "cpu_attributable",
    "in_flight_progress",
    "PROGRESSING",
    "NO_PROGRESS",
    "PROGRESS_UNKNOWN",
    "tool_veto_expired",
    "tool_from_jsonl",
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
# The LOG-LANE axis's own vocabulary. DELIBERATELY a second tuple, not an
# extension of ``STATES``: ``STATES`` is frozen by a test (the five transcript-
# derived states, unchanged since #1178) and a log lane has no transcript to
# derive any of them from. The two tuples OVERLAP on ``dead`` and ``unknown``
# on purpose — a log lane's process tree can be provably gone (``dead``) and a
# log lane can abstain (``unknown``) — and are otherwise disjoint, so no reader
# can mistake ``finished`` for a transcript state.
#
#   working    the process tree is alive AND at least one progress signal
#              advanced inside the sample window. This is the state a long
#              SILENT TOOL CALL must read: `pi -p` writes nothing to its log
#              while a tool runs, so log age alone reported such a lane as not
#              live (#…, the measured 50 %-look-dead class).
#   frozen     the process tree is alive AND ZERO progress on EVERY signal for
#              the full ``LOG_FREEZE_MS`` window. Both halves are required, and
#              the window is echoed in ``Verdict.detail`` so no reader has to
#              look it up.
#   finished   the process tree is GONE and the lane WROTE A VERDICT that says
#              its turn completed (``lane-bound.sh``'s own line).
#   no-verdict the process tree is GONE and the lane wrote NO verdict at all —
#              the process ended and told us nothing. A NEW, honest state: it
#              is what the 200–400 B artefacts of 2026-11-03 were, and reading
#              that shape as ``dead`` is the false negative this axis removes.
#
# ⛔ A PROCESS THAT HAS EXITED IS TERMINAL, NEVER ``frozen``/``working``.
# ``frozen`` is a statement about a LIVE tree that stopped progressing; a tree
# that is gone cannot be frozen, and calling it that invites a re-dispatch that
# re-does finished work.
LOG_STATES = ("working", "frozen", "finished", "no-verdict", "dead", "unknown")

# ── the log-lane bounds — every one COPIED, never invented ───────────────
# The sample window: the span between the two readings a progress delta is taken
# over. `LANE_REAP_WINDOW` default 30 s (scripts/orchestrator-harness/lane-reap.sh),
# the fleet's existing two-sample span.
LOG_WINDOW_MS = 30_000
# The freeze window: how long EVERY signal must have been flat before a LIVE tree
# is called ``frozen``. `LANE_REAP_LIVE_MIN` default 45 min — already the reviewed
# bound for "log advanced ⇒ live" — reused so ONE number answers one question
# instead of a second, unreviewed one.
# ⛔ IT IS **NOT** ABOVE THE WALL LIMIT ANY MORE, and the old rationale said it was.
# `lane.sh` now runs `run_agent "${LANE_TIMEOUT:-3300}"` (``lane.sh:387``; its own
# comment: "THE WALL LIMIT GREW BECAUSE THE JOB DID (3300s, was 2400s)") and
# `lane-bound.sh`\'s `--wall` default is likewise 3300. So 2700 s is BELOW the wall
# clock by 10 min, and the freeze window can fire on a lane still inside its allowance.
# 45 min is still the right number — it is the REAPER\'s own kill threshold
# (`lane-reap.sh` `LANE_REAP_LIVE_MIN`) and well above `lane-bound.sh`\'s 1200 s idle
# bound — but for THAT reason, not for a wall-clock ordering that no longer holds.
LOG_FREEZE_MS = 45 * 60 * 1000
# The CPU tolerance: a delta at or below this is NOT progress. `LANE_REAP_CPU_TOL_CS`
# default 10 (0.10 s) — a sub-0.1 s twitch is indistinguishable from a parked fork
# child, a human's prompt redraw, or a timer wake.
LOG_CPU_TOL_CS = 10

# The verdict vocabulary `lane-bound.sh` publishes
# (scripts/orchestrator-harness/lane-bound.sh, `verdict_line`). Parsed, never
# re-derived: the supervisor is the producer and this module is the consumer.
BOUND_VERDICTS = ("finished", "stalled", "exceeded-wallclock")
# Of those, the one that names "no bound fired". ⛔ IT IS NOT "the turn completed":
# `lane-bound.sh` writes `verdict=finished` whenever neither bound fired and puts the
# child's REAL exit status in `rc=` on the same line, so `verdict=finished rc=7` is a
# crashed lane. Measured: `lane-bound.sh run --log L -- sh -c 'exit 7'` →
# `VERDICT verdict=finished … rc=7`. `BOUND_OK_RC` is the only set that may be read as
# completion; `0` is `run` mode's success.
#
# ⛔ `na` IS **NOT** COMPLETION EVIDENCE — it is the ABSENCE of exit-status evidence.
# `lane-bound.sh` sets `V_RC=na` UNCONDITIONALLY in `watch` mode (`:397`), and `watch`
# is the mode the fleet's ONLY launcher uses for EVERY lane/fixer/worker
# (`spawn-gate.sh:1532` `run_agent` -> `lane-bound.sh watch`). `run` mode (which does
# put the child's real status on the line) is never used by the fleet. So `rc=na`
# carries no completion fact at all: reading it as OK made the `rc` conjunct INERT for
# the axis's entire production population, and a crashed / OOM-killed / watchdog-killed
# lane published `finished` — the exact false PASS the conjunct exists to remove.
# `na` is therefore NOT in `BOUND_OK_RC`; it must be CORROBORATED by the launcher's own
# `[timeout] agent pid=<pid> … rc=<n>` line (`parse_runner_line`), and only a
# corroborated `rc=0` is `finished`.
BOUND_FINISHED = frozenset({"finished"})
BOUND_OK_RC = frozenset({"0"})
_BOUND_VERDICT_RE = None  # compiled lazily, so importing the module stays cheap
_BOUND_RC_RE = None
_BOUND_PID_RE = None
_BOUND_LINE_RE = None    # the `[lane-bound] VERDICT` MARKER alone (the line, not its token)
_RUNNER_LINE_RE = None   # the LAUNCHER's own `[timeout] agent … rc=` exit-status line
# `rc=` is captured on the SAME line, because a verdict without its exit status is
# not a completion (see BOUND_OK_RC).

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
# #5389 review (cycle 4, P2): the stop reasons under which pi FAILS a truncated
# message's tool calls instead of executing them. `length` is OPEN — the loop
# continues and awaits the turn's next step (see the measurement above) — but it
# is NOT in flight: all 78 measured results after a `length`+calls message carry
# `isError: true` ("Tool call ... was not executed"). Openness and in-flight-ness
# are DIFFERENT conditions for this shape, so the transcript-derived veto must
# abstain: a phantom tool would hold the lane `running-quiet/tool-in-flight` to
# the 4 h AGE backstop where the watchdog's zero-tool `stream-stall` cuts at S,
# i.e. the classifier standing quiet where the watchdog cut (the fail-open
# divergence docs/ops/fleet-liveness.md §6 forbids). Do NOT fold this into
# `CALL_DISCARDING_STOP_REASONS`: `length` leaves the turn OPEN (T18 pins that),
# and only the VETO abstains.
CALL_FAILED_STOP_REASONS = frozenset({"length"})
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

    ``call_label`` is the transcript's own label for the open call
    (``bash(call_00_…)``). It is EVIDENCE, not a verdict input: the
    ``tool-in-flight`` row names the unwritten call so a reader can tell *which*
    step is holding the lane, exactly as the ``wedged`` row does (#5389 review
    cycle 1 P1 — the two rows must not disagree about what the tail shows).
    """

    name: str = ""
    call_label: str = ""
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


@dataclass(frozen=True)
class Claim:
    """ONE row of the fleet's ref-claim registry (#1777).

    A **ref-claim** is ``refs/claims/<pr>-<sha12>`` — a git ref whose root commit's
    message carries ``owner=<host>:<pid>`` and ``lease_until=<digits>``. That
    namespace carries TWO more key shapes as well — ``refs/claims/issue-<N>``
    (``claim_issue_key``) and the landing key ``refs/claims/pr-<N>``
    (``claim_pr_key``); ``kind`` names which shape a row is (``issue`` / ``foreign``
    for those two), because neither is HEAD-scoped and neither may answer for a
    head. This is
    the *durable, holder-authored* record of who holds a PR head, and it is the
    ONLY record that can name an orchestrator lane: ``fix-one.sh`` / ``merge-one.sh``
    spawn ``pi -p --no-session``, so those lanes write **no transcript** and have
    **no cmux hook record**. Do not confuse it with the other shipped sense of
    "claim" — the *comment-claim* (a GitHub issue comment a lane takes ownership
    with, read by the product repo's pre-flight) — nor with the product repo's
    own registry vocabulary.

    Fields are DATA, never a verdict: this dataclass asserts nothing about a
    process. ``lease_state`` is ``live``/``expired``/``unknown`` where
    ``unknown`` (an absent, ``0``, non-digit, or >18-digit value) is deliberately
    **NOT expired** — the fleet's own conservative polarity (``claims.sh``'s
    ``claim_acquire``/``claim_prune`` and ``orch-loop.sh``'s ``claim_live`` all
    treat an unparseable lease as live, and a *tighter* reading here would
    re-create the two-readers-disagree defect those sites document).
    """

    ref: str = ""
    key: str = ""            # "<pr>-<sha12>" — the content address (HEAD-scoped)
    pr: str = ""
    sha12: str = ""
    # ⛔ THREE KEY SHAPES SHARE ``refs/claims/`` (see ``claim_lanes.parse_key``): the
    # HEAD key ``<pr>-<sha12>`` (``claim_key``), the ISSUE key ``issue-<N>``
    # (``claim_issue_key``) and the LANDING key ``pr-<N>`` (``claim_pr_key``, #1952).
    # ``kind`` is ``head`` | ``issue`` | ``foreign``; ONLY a ``head`` key is
    # HEAD-scoped, so only it may answer a ``--sha`` query. Without this field
    # ``issue-1850`` parses as ``pr="issue", sha12="1850"`` and a short
    # ``--sha 1850`` reads a held head nobody holds.
    kind: str = "head"
    issue: str = ""         # the issue number, for ``kind == "issue"``
    owner: str = "?"         # as written; "<host>:<pid>"; "?" when unreadable
    owner_host: str = ""
    owner_pid: Optional[int] = None
    lease_until: Optional[int] = None
    lease_state: str = "unknown"   # live | expired | unknown
    scope: str = "unknown"         # local | foreign | unknown
    commit: str = ""               # the claim commit sha (the fence value)
    age_s: Optional[int] = None    # claim age, from the (pusher-minted) committer date


@dataclass(frozen=True)
class ClaimRead:
    """The result of reading the ref-claim registry — an ABSENCE-AWARE read.

    ``readable`` is the load-bearing field: ``False`` means the namespace could
    not be consulted at all (git failed / authenticated off / timed out / missing;
    or a snapshot that is missing, stale, or shape-drifted). An unreadable read
    must NEVER be collapsed into "no claims" — that collapse is the false-free
    this evidence exists to remove.

    ``present`` is False only for a SUCCESSFUL read that returned zero refs.
    ``claims`` therefore being empty is meaningful only when ``readable`` is True.
    ``siblings`` names the other HEAD keys seen for a queried PR: the key is
    HEAD-scoped, so an absent key is not the same as a free PR, and naming the
    siblings is how the read declares that gap.
    """

    readable: bool = False
    present: bool = False
    claims: Tuple[Claim, ...] = ()
    siblings: Tuple[str, ...] = ()
    source: str = ""
    detail: str = ""


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
    # The ref-claim registry read (#1777). None for every session-lane caller:
    # the claim logic is reachable ONLY when a caller explicitly supplies it, so
    # the existing verdict ladder is unchanged (pinned by a test + mutation).
    claim_read: Optional[ClaimRead] = None
    # The LOG-LANE evidence axis (#…). ``None`` for every session-lane caller, so
    # the existing ladder is untouched — the log logic is reachable ONLY when a
    # caller explicitly says "this is a log lane" (pinned by a test AND a
    # mutation, the same shape as the claim axis).
    log_read: Optional[LogRead] = None
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


# ── the PROGRESS verdict (#5389) ─────────────────────────────────────────
# The tri-state the watchdog's ``inFlightProgress``
# (extensions/builtin-tools/index.ts) returns, and the ONE place this module
# answers "is the in-flight tool still working?". Mirrored rather than
# re-derived: the module's own contract (see ``tool_veto_expired``) is that the
# classifier CITES the watchdog's rule and never invents one, and #5389 changed
# that rule — so a classifier still reading silence alone would be a SECOND
# contract for one rule, the defect ``docs/ops/fleet-liveness.md`` §6 names.
PROGRESSING = "progressing"
NO_PROGRESS = "no-progress"
PROGRESS_UNKNOWN = "unknown"


def in_flight_progress(tool: Tool, cpu_stall_ms: int = CPU_STALL_MS) -> str:
    """``inFlightProgress(st, cpuStallMs)`` from the watchdog (#5389).

    The second argument is the BOUND, not the measurement — mirroring the
    watchdog's signature (``builtin-tools/index.ts``), where it is
    ``i.cpuStallMs``. ``cpu_stall_ms=0`` therefore means **the channel is
    switched off** (``TASK_CPU_STALL_MS=0``), never "this tool is unprobed".

    The direction of each state is the whole point, and it is the SAME in both
    consumers:

      * ``"progressing"`` — the tool's subtree has DEMONSTRATED CPU work this
        round and is still advancing (flat for at most the bound). POSITIVE
        progress evidence: it VETOES the cut. CPU is a SPARE signal — it
        protects, it never convicts.
      * ``"no-progress"`` — demonstrated work, then flat past the bound
        (``toolCpuStallMs > cpuStallMs``). The only state that may license an
        in-flight cut.
      * ``"unknown"`` — no evidence either way. It never licenses a cut, and it
        never expires the veto on its own; the caller falls through to the AGE
        backstop.

    ``cpu_advanced`` is read FIRST, and the property that matters is which test
    does NOT exist: a `toolCpuStallMs <= 0` sentinel placed ahead of the latch.
    The not-probed sentinel is ``cpu_stall_ms == 0`` **and**
    ``cpu_advanced == False`` — so the latch alone already decides it — but a
    PROBED tool that advanced on this very tick ALSO reports
    ``cpu_stall_ms == 0``, because ``stepCpuLiveness`` stamps
    ``lastAdvanceAt = now`` on a strict increase and ``now - lastAdvanceAt == 0``.
    A sentinel-first reading files the STRONGEST progress evidence there is
    under ``"unknown"`` — measured live on the #5387 false cut, whose Alive
    state read ``toolCpuMs=135910 toolCpuStallMs=0 toolCpuAdvanced=true``.
    """
    if not tool.cpu_advanced:
        return PROGRESS_UNKNOWN
    # ``TASK_CPU_STALL_MS=0`` disables the channel; an operator who switched it
    # off has not thereby authorised a cut on it.
    if cpu_stall_ms <= 0:
        return PROGRESS_UNKNOWN
    if tool.cpu_stall_ms is None:
        return PROGRESS_UNKNOWN
    return NO_PROGRESS if tool.cpu_stall_ms > cpu_stall_ms else PROGRESSING


def tool_veto_expired(tool: Optional[Tool]) -> bool:
    """Would the watchdog's own clause have cut this in-flight tool by now? (C5)

    The classifier does not invent a bound: it cites the watchdog's clause table
    for the tool's SHAPE.

      * streamed, then stopped (``tool_updates``) — ``tool-silence``
        (index.ts:2961-2969): ``effStreamAge > S`` with S = 20 min — **AND,
        since #5389, positive no-progress evidence** (``in_flight_progress``).
        Silence alone read ABSENCE OF OUTPUT as ABSENCE OF WORK and expired this
        veto on a tool that was still burning CPU: measured, 1203 s against the
        1200 s bound with ``toolCpuAdvanced=true`` and 154 CPU-seconds burned
        (tortoise #5387).
      * never emitted an update, but demonstrated CPU work — ``tool-dead``
        (index.ts:3053-3061) is a CONJUNCTION: ``progress === "no-progress"``
        (:3057 — which is where the 30 min CPU-stall conjunct now lives) **and**
        ``effToolAge > streamStallMs`` (:3058, 20 min). 30 min binds only when the
        CPU-stall and tool-age clocks start together.
      * ``"progressing"``, ``"unknown"``, or a non-attributable tool kind — the
        AGE backstop, ``tool-stall`` (index.ts:3063-3071): ``toolStallMs`` (4h
        at the 6h cap) while the turn is ACTIVE, and
        ``min(toolStallMs, heartbeatTimeoutMs)`` (30 min) when it is NOT. The
        turn-inactive branch is the one v4 missed, and missing it is the
        fail-OPEN direction: the classifier would stay quiet for hours after
        the watchdog had already cut.

        The backstop is PROGRESS-BLIND in the watchdog — no CPU conjunct, just
        ``effToolAge > bound`` — so this is where a ``"progressing"`` tool is
        bounded too. Progress evidence defers ``tool-silence``/``tool-dead`` to
        the backstop; it does not exempt the tool from it. That is also why
        ``"unknown"`` is bounded rather than left open: a channel that cannot be
        read may not expire the veto at S, and must not keep it alive past the
        watchdog's own ceiling either. And it is why the JSONL-derived tool
        (``tool_from_jsonl``, no CPU channel at all) still bounds a fleet lane at
        4h ACTIVE / 30 min turn-inactive.

    While this returns False the tool is a VETO against ``wedged``; once it
    returns True the veto has EXPIRED (T9: the veto must never be forever).
    """
    if tool is None or tool.tools_in_flight <= 0:
        return False
    progress = in_flight_progress(tool)
    # #5389 (b): BOTH in-flight clauses require positive no-progress evidence.
    # Silence alone read ABSENCE OF OUTPUT as ABSENCE OF WORK and expired this
    # veto on a tool that was still burning CPU — measured, 1203 s against the
    # 1200 s bound with `toolCpuAdvanced=true` and 154 CPU-seconds burned
    # (tortoise #5387) — so `"progressing"` keeps the veto and `"unknown"`
    # never expires it either here.
    # Each clause RETURNS ONLY WHEN IT FIRES. A clause that does not fire must
    # fall through to the backstop below — an unconditional `return` here (which
    # is what both the pre-#5389 code and the first cut of this change did) holds
    # the veto open FOREVER for a shape whose clause is merely not yet due: a
    # `no-progress` tool whose silence is still inside S, or whose `streamAgeMs`
    # a producer omitted, would never expire at any age. That is the one outcome
    # T9 forbids, and it also diverges from the watchdog, which cuts that shape
    # at the progress-blind `tool-stall` backstop. (#5389 review, cycle 2 F1.)
    if progress == NO_PROGRESS:
        # clause 1 — `tool-silence`: streamed, then stopped.
        if tool.tool_updates and _exceeds(tool.silence_age_ms, STREAM_STALL_MS):
            return True
        # clause 1b — `tool-dead`: never streamed, but demonstrated CPU work and
        # then stopped. The watchdog guards it with `!st.toolUpdates` (the strict
        # complement of clause 1); without that guard it would expire a
        # `tool_updates=1` tool at S instead of deferring it to the backstop.
        if (not tool.tool_updates and cpu_attributable(tool)
                and _exceeds(tool.tool_age_ms, STREAM_STALL_MS)):
            return True
    # `"progressing"`, `"unknown"`, a non-attributable tool kind, and a
    # `no-progress` shape whose clause is not yet due ALL reach the watchdog's
    # AGE backstop, and that is the faithful mirror: the watchdog's `tool-stall`
    # clause (index.ts:3063-3071) has NO CPU or progress conjunct —
    # `effToolAge > bound` alone — so it cuts a tool whose CPU is STILL ADVANCING
    # once the age backstop is passed. Progress evidence buys a reprieve from
    # `tool-silence`/`tool-dead` (S = 20 min), never an exemption from the
    # backstop; an early `return False` would make the classifier stand quiet
    # where the watchdog had already cut — a second contract for one rule, in the
    # opposite direction from the one §6 names.
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


# ── the ref-claim registry (#1777) ───────────────────────────────────────
# The six reasons a claim-shaped query may return. ALL of them are `unknown`:
# true — and that is the design, not a shortfall. The five-state vocabulary has
# no state meaning "a declared owner exists but I cannot see the process", and
# `running-quiet` would make `liveness.py`'s CLI exit **0** for a claim query
# (`return 0 if verdict.state != "unknown" else 3`) — the one mapping a future
# exit-code consumer could read as a green light. `unknown` cannot be read that
# way, and the reason carries the meaning.
#
# WHY A CLAIM IS NEVER PROBED (measured, not assumed):
#   `bash scripts/lib/pid-identity.sh probe <live pid> ""` -> rc 2
#   `unusable-start-seconds` (a claim records no process start to fence against),
#   and `probe-argv <pid>` returns `holder` for ANY live pid (pure presence, no
#   identity claim). A presence-only probe mode would therefore be a SECOND
#   identity rule — the "two contracts for one safety rule" defect #1178 exists
#   to remove. So a claim asserts OWNERSHIP liveness and never incarnation
#   liveness, and `Verdict.holder_pid` is never set on a claim verdict.
CLAIM_REASONS = (
    "claims-unreadable",
    "no-claim-visible",
    "claim-owner-unparseable",
    "claim-held",
    "holder-on-foreign-box",
    "claim-holder-unverifiable",
)

# Fixed disclosure appended to the absence reason. The incident's live lane
# (a fixer committing to `fix/7951-atomic-write-outbox`) was read as "free" from
# an absence inference; this sentence is the reason the read can no longer be
# read that way.
NO_CLAIM_DISCLOSURE = (
    "key is HEAD-scoped and the registry is transient: refs are DELETED on release "
    "and PRUNED on expiry, and fix-one.sh releases its claim before merge-one.sh "
    "re-claims the new head (a designed no-claim window inside a live lane) — "
    "absence of a claim is NOT freedom"
)


def _claim_detail(claim: Optional[Claim]) -> str:
    """Owner identity, lease and age as NON-liveness detail.

    The issue's ask is that a holder be *reported* with its owner pid and age;
    the owner identity therefore rides here rather than in ``holder_pid``, so
    "who holds this?" is answered without any consumer reading the field as a
    verified incarnation. The age comes from the claim commit's committer date,
    which is pusher-minted, so it is shown as non-liveness detail only — and it is
    omitted (never invented) when the read had no commit to date (a snapshot).
    """
    if claim is None:
        return ""
    parts = ["owner=%s" % (claim.owner or "?")]
    if claim.lease_until is not None:
        parts.append("lease_until=%d" % claim.lease_until)
    parts.append("lease=%s" % claim.lease_state)
    if claim.age_s is not None:
        parts.append("age_s=%d" % claim.age_s)
    parts.append("scope=%s" % claim.scope)
    if claim.ref:
        parts.append("ref=%s" % claim.ref)
    return " ".join(parts)


def claim_verdict(cr: ClaimRead) -> Verdict:
    """The claim half of the abstention. Pure, total, and mutually exclusive.

    A DECLARED ordered cascade — the first matching rung wins, and the last is a
    catch-all, so the six reasons partition every readable/unreadable input. The
    order is the safety property: an unreadable read can never be read as an
    absence, and an absence can never be read as "free".

    Called ONLY from ``evaluate``'s existing empty-candidate-set branch, so a
    claim can never override a session verdict and can never reach ``dead``:
    ``is_dead_evidence`` requires a NON-EMPTY candidate set, and a claim-shaped
    ``Evidence`` carries none (C4's vacuity guard, #1178).
    """
    if not cr.readable:
        return Verdict("unknown", "claims-unreadable",
                       detail=cr.detail or ("source=%s" % (cr.source or "unknown")))
    if not cr.claims:
        detail = NO_CLAIM_DISCLOSURE
        if cr.siblings:
            detail += "; claims exist for other heads of this PR: %s" % ", ".join(cr.siblings)
        return Verdict("unknown", "no-claim-visible", detail=detail)
    if any(c.scope == "unknown" for c in cr.claims):
        bad = next(c for c in cr.claims if c.scope == "unknown")
        return Verdict("unknown", "claim-owner-unparseable",
                       detail="%s (owner string unusable)" % _claim_detail(bad))
    held = [c for c in cr.claims if c.lease_state in ("live", "unknown")]
    if held:
        # OWNERSHIP liveness only — the declared lease window is open. This
        # asserts nothing about the holder's process (see the header note).
        return Verdict("unknown", "claim-held",
                       detail="%s (declared ownership window; process liveness not asserted)"
                              % _claim_detail(held[0]))
    foreign = [c for c in cr.claims if c.scope == "foreign"]
    if foreign:
        # A foreign owner's pid is NOT probeable here (measured: agent-infra's
        # live refs are `owner=cmux:<pid>` while this host is
        # `Daniels-MacBook-Air-new`), and probing one is actively wrong: a local
        # pid collision can read `absent`, and `absent` is a death witness.
        return Verdict("unknown", "holder-on-foreign-box",
                       detail="%s (foreign owner is never probed locally)" % _claim_detail(foreign[0]))
    return Verdict("unknown", "claim-holder-unverifiable",
                   detail="%s (no open lease; no probeable incarnation)" % _claim_detail(cr.claims[0]))


# ── the LOG-LANE axis: a lane that writes a log and no transcript ────────
#
# WHY THIS AXIS EXISTS (the measured defect, 2026-11-03)
# ------------------------------------------------------
# An orchestrator lane runs `pi -p --no-session`, so it writes NO transcript and
# leaves NO cmux store record — the population gap #1777 declares. The only
# artefact it leaves is its LOG (`L-<slug>.log` / `lane-<n>.log`). Every reader
# that judged such a lane keyed on that file's **mtime**, and mtime is not a
# liveness signal:
#
#   1. **a `pi -p` lane writes NOTHING to its log while a tool call runs.** The
#      mtime freezes while the lane is working hard. Measured over one session:
#      `land-10762` froze at 18:46 and was called dead at 19:07, and its log in
#      fact ends `session (27 turns, 2 PRs) saved` with the reflect-hook ran —
#      it had FINISHED. `harness-provision-cells` was called dead at 19:00 over a
#      210 B artefact whose tail is `[verification-gate] ✅ 7 files verified` +
#      `[review-enforcer] ✅ 3 reviewer dispatches`. Only `p0-10537` / `p0-5064`
#      were genuinely frozen, and their re-dispatch WAS necessary. So ~50 % of
#      "dead" lanes were finished and only ~8 % were dead.
#   2. **the verdict the supervisor ALREADY WRITES was never read.**
#      `lane-bound.sh` emits ONE line — `[lane-bound] VERDICT verdict=finished|
#      stalled|exceeded-wallclock …` — to the log, to stdout and to
#      `--verdict-file`. Measured 2026-11-03: nothing under `tools/fleet/` reads
#      it, so a lane that finished without an exit-status a reader recognised was
#      indistinguishable from a crash. `test-gates.sh` already uses the word
#      `NO-VERDICT` for exactly this shape in review verdicts; this axis adopts
#      the same name rather than inventing a parallel one.
#   3. real death: the completion watchdog's
#      `sub-agent completed but did not exit within 15s — killing`, a provider
#      stall, or a true hang — and `lane-bound.sh`'s own `verdict=stalled` /
#      `verdict=exceeded-wallclock` lines ARE that death, reported.
#
# ⛔ ONE VERDICT FUNCTION. This is an AXIS of ``evaluate`` (a new evidence field,
# like ``claim_read``), not a second classifier: ``log_lane_verdict`` is reached
# ONLY from ``evaluate``, is inert when ``log_read is None`` (pinned by a test),
# and no parallel implementation exists anywhere in the tree. The alternatives
# considered and rejected: a new `tools/fleet/log_liveness.py` (that IS the second
# verdict function this rule forbids) and widening ``lane_liveness.py``'s
# population to include log lanes (its population and every escalation policy
# around it are cmux-keyed; that is a different change with a different blast
# radius).
#
# ⛔ THE PROGRESS CONTRACT IS COPIED FROM `lane-bound.sh`, NOT INVENTED.
# That file already states the rule this axis implements, in its own header:
# "TWO INDEPENDENT SIGNALS, AND BOTH MUST BE QUIET — THAT IS THE DISTINCTION. A
# lane is killed only when it has shown NO OUTPUT GROWTH **and** NO CPU DELTA for
# the idle window. Either signal advancing keeps it alive however long it runs …
# a single 11 h test against a 26 m slowest shard is SLOW (its subtree burns CPU)
# and is never touched; a `pi` parked in `ep_poll` is STALLED (both signals flat)".
# The two signals are therefore:
#
#   S1  OUTPUT GROWTH — the log's BYTE SIZE, `wc -c` semantics, not its mtime.
#       A `tee` re-emits bytes while the lane prints, so a size delta across the
#       sample window is positive evidence of work that mtime only approximates.
#   S2  CPU DELTA — cumulative CPU of the lane's process TREE, two readings
#       ``LOG_WINDOW_MS`` apart, compared strictly above ``LOG_CPU_TOL_CS``.
#       **This is the signal that survives a long silent tool call**: a tool that
#       prints nothing still burns CPU, so a lane at 0 bytes for 40 minutes but
#       +154 CPU-seconds is WORKING (measured, tortoise #5387: 1203 s of silence
#       at `toolCpuAdvanced=true`, 154 CPU-seconds burned).
#
# Resolution, measured on this host: a 30 s window with a 0.10 s tolerance
# resolves S2 to **0.10 CPU-seconds per 30 s** (≈3.3 mCPU). A `pi` parked in
# `ep_poll` reads exactly 0 cs; an active lane reads tens to hundreds.
#
# ⛔ AND THE DIRECTION OF EACH RULE IS THE SAFETY PROPERTY. Progress is a VETO
# (it protects, it never convicts); ``frozen`` needs BOTH signals flat for the
# FULL ``LOG_FREEZE_MS`` AND a live tree; an unreadable signal ABSTAINS
# (``unknown``) and never becomes ``frozen`` or ``dead``; and absence of a log is
# an ABSTENTION — never death.


def _bound_pid_re():
    global _BOUND_PID_RE
    if _BOUND_PID_RE is None:
        _bound_verdict_re()
    return _BOUND_PID_RE


def _bound_pid_field_re():
    global _BOUND_PID_FIELD_RE
    if _BOUND_PID_FIELD_RE is None:
        _bound_verdict_re()
    return _BOUND_PID_FIELD_RE


def _bound_rc_re():
    global _BOUND_RC_RE
    if _BOUND_RC_RE is None:
        _bound_verdict_re()
        assert _BOUND_RC_RE is not None
    return _BOUND_RC_RE


def _bound_verdict_re():
    # ⛔ ALL THREE, DECLARED `global`, ASSIGNED DIRECTLY (review P2). This block lazy-inits the
    # sibling patterns that `_bound_rc_re` / `_bound_pid_re` consume, so it must bind them in the
    # MODULE namespace. It used to do that for two of the three through `globals()[...]` while the
    # third was a plain assignment under a `global _BOUND_VERDICT_RE` declaration — which made
    # `_BOUND_RC_RE = _re.compile(...)` a LOCAL, compiling the pattern twice and discarding one.
    # It happened to work only because the `globals()` write came first, so deleting that line as
    # "redundant with the next one" would have silently broken `_bound_rc_re`'s
    # `assert _BOUND_RC_RE is not None`. Four entries, one idiom, nothing to trip over.
    # The fourth (`_BOUND_PID_FIELD_RE`) records that a `pid=` FIELD was present at all, which
    # `_BOUND_PID_RE` alone cannot distinguish from the field being absent — see
    # `parse_bound_pid`'s DROP-vs-ADOPT split.
    global _BOUND_VERDICT_RE, _BOUND_RC_RE, _BOUND_PID_RE, _BOUND_PID_FIELD_RE
    if _BOUND_VERDICT_RE is None:
        import re as _re
        # ⛔ THE VERDICT TOKEN AND THE `rc=` ARE PARSED SEPARATELY, for three reasons
        # that each produced a wrong state when they were one regex:
        #   * requiring `rc=` INSIDE the match made a recognised verdict with no `rc=`
        #     return ("", None) — `no-verdict` instead of the documented
        #     `finished-rc-unreadable` abstention;
        #   * a greedy `.*\brc=` swallows an `rc=` in a later field, so
        #     `log=/tmp/L-rc=5.log` supplied the exit status;
        #   * a non-greedy one takes an earlier `rc=`-shaped field (`tag=rc=7`).
        # So: match the token alone, then scan that line's HEAD (everything before
        # ` log=`) for `rc=` and take the LAST one.
        _BOUND_VERDICT_RE = _re.compile(r"\[lane-bound\]\s+VERDICT\b.*?\bverdict=([a-z][a-z-]*)")
        _BOUND_RC_RE = _re.compile(r"\brc=([0-9]+|na)\b")
        globals()["_BOUND_PID_RE"] = _re.compile(r"\bpid=([0-9]+)\b")
        # ⛔ THE MARKER ALONE, with NO token requirement. `_BOUND_VERDICT_RE` demands
        # `verdict=` followed by `[a-z][a-z-]*`, so a FINAL line whose token is
        # uppercase, empty, or spaced (`verdict = stalled`) produced NO match and the
        # parser silently returned the PREVIOUS line's verdict — measured:
        # `"…verdict=finished … rc=0\n…VERDICT verdict=None … rc=0"` -> ('finished','0').
        # That is the stale-verdict false PASS the "last line wins" rule exists to stop,
        # so the MARKER is located first and the token is read off THAT line only.
        globals()["_BOUND_LINE_RE"] = _re.compile(r"\[lane-bound\]\s+VERDICT\b")
        _BOUND_LINE_RE = globals()["_BOUND_LINE_RE"]
        _BOUND_TOKEN_RE = _re.compile(r"\bverdict=([a-z][a-z-]*)")
        globals()["_BOUND_TOKEN_RE"] = _BOUND_TOKEN_RE
        # The LAUNCHER's exit-status line (`spawn-gate.sh:1583`):
        #   [timeout] agent pid=<pid> wall_limit=<t>s elapsed=<e>s rc=<n>
        # It is the ONLY witness of the child's real status in `watch` mode, so it is
        # what corroborates `rc=na` (see BOUND_OK_RC).
        globals()["_RUNNER_LINE_RE"] = _re.compile(
            r"\[timeout\]\s+agent\s+pid=(\d+)\b[^\n]*?\brc=([^\s]+)")
        _RUNNER_LINE_RE = globals()["_RUNNER_LINE_RE"]
    return _BOUND_VERDICT_RE


def _last_bound_line(text: str):
    """The LAST ``[lane-bound] VERDICT`` LINE in ``text``, or ``None``.

    ONE locator, shared by :func:`parse_bound_line` and :func:`parse_bound_pid`, so
    "the line" cannot mean two different lines in the two parsers. It matches the
    MARKER only — never the verdict token — so a final line the token regex cannot
    match still *is* the final line, and its unreadable token yields "no verdict"
    instead of silently promoting an earlier recognised one.
    """
    if not text:
        return None
    _bound_verdict_re()  # ensures the compiled globals exist
    last = None
    for m in _BOUND_LINE_RE.finditer(text):
        last = m
    if last is None:
        return None
    line_end = text.find("\n", last.start())
    return text[last.start(): line_end if line_end >= 0 else len(text)]


def parse_runner_line(text: str):
    """``(pid, rc)`` from the LAST launcher ``[timeout] agent … rc=`` line, or ``("", None)``.

    ⛔ WHY THIS EXISTS — THE `rc=na` HOLE. `lane-bound.sh` writes
    ``VERDICT verdict=finished … rc=na`` UNCONDITIONALLY in ``watch`` mode
    (``lane-bound.sh:397``), and ``watch`` is the mode ``spawn-gate.sh``'s ``run_agent``
    uses for EVERY lane/fixer/worker (``spawn-gate.sh:1532``). ``run`` mode — the only
    one that puts the child's real status on the bound line — is never used by the
    fleet. So the bound line's ``rc`` can NEVER witness completion in production, and a
    crashed / OOM-killed / watchdog-killed lane wrote exactly the same
    ``verdict=finished rc=na``.

    The real status IS written to the same log, one line later, by the caller:
    ``[timeout] agent pid=<pid> wall_limit=<t>s elapsed=<e>s rc=<n>``
    (``spawn-gate.sh:1583``). That line is the corroborating witness for ``na``.

    Last line wins (the log is appended to across dispatches), and ``pid`` is returned so
    the caller can require it belong to the SAME incarnation as the bound line.
    """
    if not text:
        return "", None
    _bound_verdict_re()  # ensures the compiled globals exist
    last = None
    for m in _RUNNER_LINE_RE.finditer(text):
        last = m
    if last is None:
        return "", None
    return last.group(1), last.group(2)


def parse_bound_line(text: str):
    """``(verdict, rc)`` from the LAST ``[lane-bound] VERDICT`` line, or ``("", None)``.

    ``rc`` is the child's real exit status, and it is what separates "no bound
    fired" from "the turn completed": ``lane-bound.sh`` writes ``verdict=finished``
    for BOTH, and only ``rc`` tells them apart (measured: ``sh -c 'exit 7'`` under
    the bound yields ``verdict=finished ... rc=7``). It is returned as a STRING so
    ``"na"`` (``watch`` mode) keeps its own meaning instead of coercing to 0.

    The ``rc`` is read from the SAME line as the verdict: a verdict whose ``rc=``
    is missing or unparseable yields ``rc=None``, which is an ABSTENTION
    (``finished-rc-unreadable``), never an assumed success.
    """
    if not text:
        return "", None
    # ⛔ THE LAST LINE WINS, RECOGNISED OR NOT. Keeping the last RECOGNISED verdict
    # silently adopts a STALE earlier one when the final status line carries a token
    # this module does not model — measured: `...verdict=finished ... rc=0` followed by
    # `VERDICT verdict=needs-review ... rc=0` parsed as `finished`, which is the
    # false-PASS class this axis exists to remove. An unrecognised final token is
    # "no verdict", never "the previous one".
    #
    # ⛔ THAT RULE IS ONLY TRUE IF THE *LINE* IS LOCATED, NOT THE TOKEN. Locating the
    # last `verdict=<lowercase-token>` MATCH lets a final line the token regex cannot
    # match — uppercase, empty, or spaced (`verdict = stalled`) — simply not exist, so
    # an earlier `finished` is returned. Measured before this fix:
    #   "…verdict=finished … rc=0\n…VERDICT verdict=FINISHED … rc=0" -> ('finished','0')
    #   "…verdict=finished … rc=0\n…VERDICT tag=t pid=1 rc=0"     -> ('finished','0')
    # Both are a stale false PASS. So: find the last MARKER, then read the token on
    # that line, and an unreadable token there is NO VERDICT.
    line = _last_bound_line(text)
    if line is None:
        return "", None
    tok = _BOUND_TOKEN_RE.search(line) if globals().get("_BOUND_TOKEN_RE") else None
    if tok is None:
        # A FINAL marker whose token is missing/unparseable is "no verdict".
        return "", None
    verdict = tok.group(1)
    if verdict not in BOUND_VERDICTS:
        # An unrecognised FINAL token is "no verdict", never the previous one.
        return "", None
    # The `rc=` lives on the SAME line, before ` log=`. A missing/unparseable one is
    # None, which the verdict function turns into `finished-rc-unreadable`.
    head = line.split(" log=")[0]
    rcs = _bound_rc_re().findall(head)
    return (verdict, rcs[-1] if rcs else None)


def parse_bound_pid(text: str):
    """The ``pid=`` named on the LAST ``[lane-bound] VERDICT`` line, or ``""``.

    ⛔ WHY A VERDICT NEEDS A PID AT ALL: the lane log is APPENDED to across
    dispatches (`lane.sh` uses ``tee -a`` / ``>>`` and nothing truncates the file), so
    an earlier run's ``[lane-bound] VERDICT verdict=finished ... rc=0`` stays in the
    tail until new output pushes it out of the 8 KiB window. Adopting it publishes a
    PREVIOUS dispatch's outcome as this lane's — a false PASS over work that was never
    re-dispatched, which is the class this axis exists to remove. Measured: the tail
    ``"[lane 3] cwd=...\n[lane-bound] VERDICT verdict=finished ... rc=0\n[lane 3]
    exited 0\n=== next dispatch ===\n"`` parsed as ``('finished', '0')``.
    """
    if not text:
        return ""
    # The PID must come from the same LAST MARKER line `parse_bound_line` reads, or the
    # two functions disagree about which line is "the line" (they did while each carried
    # its own `last-match` loop — the defect `_bind_verdict` exists to prevent).
    line = _last_bound_line(text)
    if line is None:
        return ""
    pids = _bound_pid_re().findall(line.split(" log=")[0])
    # A pid is <= 7 digits (PID_MAX_DEFAULT 4194304). A longer token is not a pid, and
    # `int()` on it raises "Exceeds the limit (4300 digits)" — an exception, not a state.
    if not pids:
        # ⛔ A `pid=` FIELD THAT IS PRESENT BUT UNPARSEABLE IS NOT AN ABSENT ONE (review P2).
        # "Absent from the line" is the ADOPT row of the doc's binding table; "a pid that cannot
        # be resolved" is the DROP row. This returned "" for both, so a line carrying `pid=abc`
        # took the ADOPT arm and published a verdict whose binding was never checked.
        #
        # WHERE SUCH A LINE COMES FROM — stated narrowly, because the first version of this
        # comment overclaimed it and a later reviewer falsified the claim. It is NOT the shipped
        # writer: `lane-bound.sh --pid` takes the value verbatim (`:161`) but no emission path can
        # carry a non-numeric one — `watch` mode refuses first (`:465` → `pid_alive`, whose
        # `case "${1:-}" in *[!0-9]*) return 1` guard at `:234` has been on `main` since the bound
        # was introduced) and `run` mode overwrites `PID=$!` (`:475`). Measured:
        # `lane-bound.sh watch --log … --pid abc` → "refusing: --pid 'abc' is not a live
        # process — nothing to bound", rc=2, nothing emitted. So the producers that reach this
        # arm are a FOREIGN or hand-edited verdict file (`$log.lanebound`), a restored state dir,
        # or a FUTURE producer — the same producer class this file names for every other hostile
        # state value. That makes this defence in depth, not a live production bypass, and the
        # guard is justified without the overclaim: the doc's binding table requires the DROP row
        # for an unresolvable pid, and `_bind_verdict`'s `invalid-bound-verdict-pid` arm already
        # existed for a non-pid token but was UNREACHABLE from this parser — which is what marks
        # the intent. `"?"` reaches it.
        # `\bpid=` does not match `ppid=` / `cpu_delta_cs=` (a word boundary needs a non-word
        # char before `p`), so this only fires on a real `pid=` field.
        if _bound_pid_field_re().search(pid_head):
            return "?"
        return ""
    # A pid token is capped at 10 digits DEFENSIVELY, not because `PID_MAX_DEFAULT` (4194304)
    # is 7 digits long. The cap exists so `int()` below never sees a 4300-digit token and
    # raises "Exceeds the limit" — an exception is not a state. Any token longer than the cap
    # is NOT a pid.
    # `"?"` marks "present but unusable", which the binding DROPS; `""` means "the line
    # names no incarnation", which is ADOPTED and declared.
    return pids[-1] if len(pids[-1]) <= 10 else "?"


def _pid_within(root: int, child: int, *, hops: int = 64):
    """Is ``child`` ``root`` itself or inside ``root``'s tree? ``None`` = unverifiable.

    The ppid chain is read from ``/proc`` where it exists and from ``ps`` otherwise.
    ``None`` (unverifiable) is NOT "no": the caller decides, and it fails closed.

    ⛔ LIMITATION, STATED BECAUSE IT IS LOAD-BEARING: the chain is read from the LIVE
    process table, and a verdict is only *used* when ``alive is False`` — i.e. when the
    tree has already EXITED. Measured: a real parent/child pair returns ``True`` while
    both are alive and ``None`` immediately after they exit, and ``None`` DROPS the
    verdict (``unbound-bound-verdict``). So after exit only EXACT PID EQUALITY (the
    ``child == root`` short-circuit) survives, and a verdict naming a genuine
    DESCENDANT of the queried pid degrades to ``no-verdict``. That direction is the
    safe one (an abstention, never a false PASS) and it is why the doc's binding table
    says row 2 holds only while the tree is live. A durable identity (the launcher's
    ``pid=``-carrying ``[timeout] agent`` line, or a dispatch/incarnation id on the
    bound line) is the real fix and is a separate change.
    """
    if child == root:
        return True
    cur = child
    for _ in range(hops):
        par = _parent_of(cur)
        if par is None:
            return None
        if par == root:
            return True
        if par <= 1:
            return False
        cur = par
    return None


def _parent_of(pid: int):
    try:
        raw = open("/proc/%d/stat" % pid, "rb").read().decode("utf-8", "replace")
        close = raw.rfind(")")
        if close < 0:
            return None
        return int(raw[close + 2:].split()[1])
    except (OSError, ValueError, IndexError):
        pass
    ps = os.environ.get("PS_BIN") or "ps"
    try:
        out = subprocess.run([ps, "-o", "ppid=", "-p", str(pid)],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=30).stdout.decode("utf-8", "replace").strip()
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    return int(out) if out.isdigit() else None


def parse_bound_verdict(text: str) -> str:
    """The last ``[lane-bound] VERDICT verdict=<v>`` in ``text``, or ``""``.

    ``lane-bound.sh`` writes ONE status line per lane and it is the LAST line of
    a finished lane's log ("Emitting twice would break the 'one status line'
    contract an operator reads with `tail -1`"), so the LAST match wins. A
    verdict value outside ``BOUND_VERDICTS`` is NOT adopted — an unrecognised
    token is an abstention-shaped fact, and adopting it would let a future
    producer's new spelling decide a state this module has never reasoned about.
    Returning ``""`` is therefore "no verdict", never "some verdict".
    """
    return parse_bound_line(text)[0]


@dataclass
class LogRead:
    """The evidence for a LOG-LANE. Absent fields are ``None``, never ``0``.

    The distinction that carries the whole axis: ``None`` means "not read", and
    an unread signal ABSTAINS. Only a POSITIVE ``alive is False`` can be terminal,
    and only a POSITIVE pair of flat signals can be ``frozen``.

    ``age_ms`` is the log's mtime age and it is REPORTED, never decisive — that is
    the one thing this axis exists to stop doing. It is consulted for exactly one
    question: *how long has nothing changed?*, and only AFTER both progress
    signals have already read flat. A lane burning CPU with a 3 h-old log is
    ``working``, not ``frozen``.
    """

    readable: bool = False          # could the log be read at all?
    present: bool = False           # did the log EXIST (readable+"absent" are different facts)
    path: str = ""
    size: Optional[int] = None      # bytes now
    size_delta: Optional[int] = None    # S1: bytes gained across the sample window
    # S1b: did the lane's TRANSCRIPT advance across the window? Only a lane
    # launched WITHOUT `--no-session` has one (`scripts/orchestrator-harness`
    # launches `pi -p --no-session`, so this is usually ``None`` — "no transcript",
    # which is an ABSTENTION on this signal and never a flat one).
    transcript_grew: Optional[bool] = None
    age_ms: Optional[int] = None        # mtime age — REPORTED, never decisive
    cpu_delta_cs: Optional[int] = None  # S2: subtree CPU gained across the window
    cpu_unreadable: bool = False        # the CPU read failed (an abstention, never flat)
    alive: Optional[bool] = None        # process-tree existence: True/False/None
    verdict: str = ""               # BOUND_VERDICTS member, or ""
    rc: Optional[str] = None        # the bound's `rc=` on the same line: "0" | "na" | "7" …
    # The LAUNCHER's own exit status for this lane (`[timeout] agent … rc=<n>`,
    # `spawn-gate.sh:1583`). REQUIRED to corroborate `rc=na`, which is `watch` mode's
    # shape and carries NO completion fact (see `BOUND_OK_RC`).
    runner_rc: Optional[str] = None
    verdict_line_pid: str = ""      # the `pid=` on that line — the verdict's own incarnation
    verdict_source: str = ""        # "log" | "verdict-file" | "caller" | ""
    window_ms: int = LOG_WINDOW_MS
    detail: str = ""


def _also(detail: str) -> str:
    """``" | <detail>"`` when there is one — the append idiom, never a substitution."""
    return (" | " + detail) if detail else ""


def _bind_verdict(lr: "LogRead", pid: int):
    """Adopt ``lr``'s verdict only if it names THIS incarnation.

    Returns ``(why_dropped, note)``. ONE implementation, because the rule is needed by
    `gather_log_lane` AND by `--log-census`, and two copies had already drifted: the
    census adopted an unbound row silently, so the fifth rule of the doc's binding table
    ("adopted, and said so") was false on the surface §13.5 names as the fleet reader's
    home.
    """
    line_pid = lr.verdict_line_pid
    if line_pid == "?":
        return ("unbound-bound-verdict line_pid=? query_pid=%s source=%s"
                % (pid, lr.verdict_source), "")
    if not line_pid:
        return None, "bound-verdict-without-pid source=%s" % (lr.verdict_source or "log")
    # DEFENCE IN DEPTH, and it must be DISTINGUISHABLE from the cap above: a token that is
    # not a pid at all is dropped with its own reason, so a caller that bypasses
    # `parse_bound_pid` cannot turn the drop into an `int()` exception.
    if not (line_pid.isascii() and line_pid.isdigit() and len(line_pid) <= 10):
        return ("invalid-bound-verdict-pid line_pid=%s source=%s"
                % (line_pid[:16], lr.verdict_source), "")
    within = _pid_within(int(pid), int(line_pid))
    if within is False:
        return ("stale-bound-verdict line_pid=%s query_pid=%s source=%s"
                % (line_pid, pid, lr.verdict_source), "")
    if within is None:
        return ("unbound-bound-verdict line_pid=%s query_pid=%s source=%s"
                % (line_pid, pid, lr.verdict_source), "")
    return None, ""


def log_lane_verdict(lr: Optional[LogRead], *, freeze_ms: int = LOG_FREEZE_MS,
                     cpu_tol_cs: int = LOG_CPU_TOL_CS) -> Verdict:
    """The log-lane state. PURE and TOTAL: every input maps to one state.

    The ladder is DECLARED and ordered, and the order is the safety property:
    identity first (it is the only source of a terminal state), then progress
    (a veto), then — only with both signals flat and the full window elapsed —
    ``frozen``. Every unreadable branch abstains. Nothing here can reach
    ``frozen`` without a LIVE tree, a STATED window, and ZERO progress on every
    signal, and nothing can reach ``finished``/``no-verdict`` without positive
    evidence that the tree is gone.
    """
    if lr is None:
        return Verdict("unknown", "no-log-read")
    if not lr.readable:
        # Absence (or an unreadable file) is an ABSTENTION — never death. This is
        # the `no-log-evidence` refusal `lane-reap.sh` already made for the reaper;
        # the same rule applies to the diagnostic.
        return Verdict("unknown", "log-unreadable", detail=lr.detail or ("path=%s" % (lr.path or "?")))

    # (1) IDENTITY — the only source of a TERMINAL state.
    if lr.alive is False:
        # ⛔ A PROCESS THAT HAS EXITED IS TERMINAL, NEVER `frozen`.
        # ⛔ AND AN UNMODELLED TOKEN IS NOT A VERDICT. Normalising here (not only in the
        # two parsers) is what stops a direct caller — the reader §13.5 says is next —
        # from turning a future producer's new spelling into `dead/bound-verdict:<it>`.
        # `parse_bound_line` and the census seam both filter; this is the third door.
        verdict = lr.verdict if lr.verdict in BOUND_VERDICTS else ""
        if verdict:
            if verdict in BOUND_FINISHED:
                # ⛔ `verdict=finished` ALONE IS NOT A COMPLETION — it means "no bound
                # fired", and the child's real status is on the same line. Measured:
                # `lane-bound.sh run --log L -- sh -c 'exit 7'` → `verdict=finished rc=7`.
                # Reading that as finished is a FALSE PASS over lost work: nobody
                # re-dispatches it, and the lane's turn never completed.
                if lr.rc is None:
                    return Verdict("unknown", "finished-rc-unreadable",
                                   detail="verdict=finished but no rc= on the line; "
                                          "completion is undecidable")
                if lr.rc == "na":
                    # ⛔ `na` IS NOT COMPLETION — IT IS THE ABSENCE OF EXIT-STATUS
                    # EVIDENCE. `lane-bound.sh watch` writes it UNCONDITIONALLY
                    # (`:397`) and `watch` is what `spawn-gate.sh`'s `run_agent` uses
                    # for EVERY lane/fixer/worker (`:1532`), so in the fleet's actual
                    # population `finished` + `rc=na` is written by a lane that
                    # COMPLETED and by a lane that CRASHED, was OOM-killed, or was
                    # killed by the completion watchdog's 15 s TERM->KILL —
                    # identically. Accepting `na` on its own made the `rc` conjunct
                    # INERT for that whole population and published `finished` for a
                    # crashed lane: the false PASS over lost work this conjunct exists
                    # to remove.
                    #
                    # The real status IS in the same log, one line later, from the
                    # caller: `[timeout] agent pid=<pid> … rc=<n>` (`spawn-gate.sh:1583`).
                    # Corroborate with it, and require it to describe THIS incarnation.
                    if lr.runner_rc is None:
                        return Verdict("unknown", "finished-rc-uncorroborated",
                                       detail=("verdict=finished rc=na and no launcher "
                                               "`[timeout] agent … rc=` line to corroborate "
                                               "it; completion is undecidable")
                                              + _also(lr.detail))
                    if lr.runner_rc != "0":
                        return Verdict("no-verdict", "bound-finished-runner-rc:%s" % lr.runner_rc,
                                       detail=("verdict=finished rc=na but the launcher "
                                               "reported rc=%s — the bound fired nothing, "
                                               "yet the child did NOT complete" % lr.runner_rc)
                                              + _also(lr.detail))
                    return Verdict("finished", "bound-verdict:%s" % verdict,
                                   detail=("verdict_source=%s rc=na runner_rc=0"
                                           % (lr.verdict_source or "log"))
                                          + _also(lr.detail))
                if lr.rc not in BOUND_OK_RC:
                    return Verdict("no-verdict", "bound-finished-rc:%s" % lr.rc,
                                   detail=("verdict=finished rc=%s — the bound fired nothing, "
                                           "but the turn did NOT complete" % lr.rc)
                                          + _also(lr.detail))
                return Verdict("finished", "bound-verdict:%s" % verdict,
                               detail=("verdict_source=%s rc=%s"
                                       % (lr.verdict_source or "log", lr.rc))
                                      + _also(lr.detail))
            # `stalled` / `exceeded-wallclock` — the bound's own kill verdict. That is
            # REAL DEATH (mechanism 3), reported by the producer that caused it.
            return Verdict("dead", "bound-verdict:%s" % verdict,
                           detail=("verdict_source=%s rc=%s"
                                   % (lr.verdict_source or "log", _n(lr.rc)))
                                  + _also(lr.detail))
        return Verdict("no-verdict", "process-gone-no-verdict",
                       detail=("bytes=%s age_ms=%s (the process ended and told us nothing)"
                               % (_n(lr.size), _n(lr.age_ms)))
                              + ((" | " + lr.detail) if lr.detail else ""))
    if lr.alive is None:
        return Verdict("unknown", "process-identity-unreadable", detail=lr.detail)

    # (2) PROGRESS — a VETO. Either signal advancing is positive evidence of work.
    kinds = []
    if lr.size_delta is not None and lr.size_delta > 0:
        kinds.append("bytes")
    if lr.cpu_delta_cs is not None and lr.cpu_delta_cs > cpu_tol_cs:
        kinds.append("cpu")
    if lr.transcript_grew is True:
        kinds.append("transcript")
    if kinds:
        numbers = []
        if "bytes" in kinds:
            numbers.append("bytes+%d" % (lr.size_delta or 0))
        if "cpu" in kinds:
            numbers.append("cpu+%dcs" % (lr.cpu_delta_cs or 0))
        if "transcript" in kinds:
            numbers.append("transcript-grew")
        return Verdict("working", "progress:%s" % "+".join(kinds),
                       detail="%s window_ms=%d tol_cs=%d"
                              % (" ".join(numbers), lr.window_ms, cpu_tol_cs))

    # (3) ANY single signal that could not be read is an ABSTENTION — never "flat".
    # ⛔ THE CONJUNCT IS `or`, AND THAT IS THE WHOLE SAFETY PROPERTY. With `and`, a
    # readable-but-flat log plus an UNREADABLE CPU channel fell through to `frozen`
    # — i.e. `frozen` on ONE signal, which is the log-mtime behaviour this axis
    # exists to delete (a lane working through a long silent tool call has exactly
    # that shape: byte-static log, CPU the only witness).
    # A NEGATIVE BYTE DELTA IS A BROKEN READING, NOT A FLAT ONE — the identical rule
    # this function applies to CPU a few lines below. A log cannot lose bytes without
    # activity (truncate/rotate/replace, or a negative field handed in by a census
    # caller), so a shrink proves the window was mis-measured. Read as "flat" it froze a
    # lane whose log had just been REWRITTEN: measured `size_delta=-990 cpu=0 alive=True
    # age_ms=3h` -> `frozen/no-progress`.
    # Only a POSITIVELY FLAT byte reading counts as "no output": a shrink is a broken
    # reading and an unread field is not evidence. The transcript may VETO (a growing
    # transcript is work) but can never manufacture the flat reading — with `and
    # lr.transcript_grew is None` a positively-flat transcript suppressed the abstention
    # and froze a lane whose log had just been REWRITTEN with its own contradicting
    # evidence (`bytes_delta=-990`) printed in the detail.
    # `no_output` here means THE OUTPUT CHANNEL COULD NOT BE READ, and it abstains.
    # A shrink is broken (a log cannot lose bytes without activity) and an unread field
    # is not evidence; a POSITIVELY FLAT transcript must not rescue either, which is what
    # `is not True` says — round 6's `is None` let `size_delta=-990` + `transcript_grew=
    # False` through to `frozen`, printing its own contradicting evidence in the detail.
    # A growing transcript still vetoes upstream (it is a progress kind).
    no_output = ((lr.size_delta is None or lr.size_delta < 0)
                 and lr.transcript_grew is not True)
    # A negative delta is a BROKEN reading, not a flat one — same rule as the reaper's.
    # The census seam can be handed one in field 3, so the check lives here too.
    no_cpu = (lr.cpu_unreadable or lr.cpu_delta_cs is None or lr.cpu_delta_cs < 0)
    if no_output or no_cpu:
        # The reason names the CLASS; the detail must name the FACT, or a reader cannot
        # tell a rotated log from a failed `ps` read from a caller's `?`, while the two
        # neighbouring branches both print their numbers.
        return Verdict("unknown", "no-progress-signal-readable",
                       detail=("bytes_delta=%s transcript_grew=%s cpu_delta_cs=%s "
                               "cpu_unreadable=%s window_ms=%d"
                               % (_n(lr.size_delta), _n(lr.transcript_grew),
                                  _n(lr.cpu_delta_cs), int(bool(lr.cpu_unreadable)),
                                  lr.window_ms)) + _also(lr.detail))
    if lr.age_ms is None:
        return Verdict("unknown", "log-age-unreadable", detail=lr.detail)

    # (4) Both signals flat. Inside the window the lane is still working — a
    #     short flat stretch is the fleet's normal resting state, not a freeze.
    if lr.age_ms < freeze_ms:
        # ⛔ `freeze_ms=` AND `window_ms=` ARE DIFFERENT WINDOWS and both are named:
        # `freeze_ms` is the inactivity window that decides this branch, `window_ms` is
        # the sample span the deltas were taken over. One name for two numbers made a
        # machine reader unable to tell which it had received.
        return Verdict("working", "within-window",
                       detail="bytes_delta=%s cpu_delta_cs=%s age_ms=%d freeze_ms=%d window_ms=%d"
                              % (_n(lr.size_delta), _n(lr.cpu_delta_cs), lr.age_ms, freeze_ms,
                                 lr.window_ms))

    # (5) FROZEN — live tree, ZERO progress on every signal, full window elapsed.
    return Verdict("frozen", "no-progress",
                   detail="bytes_delta=%s transcript_grew=%s cpu_delta_cs=%s tol_cs=%d "
                          "age_ms=%d freeze_ms=%d window_ms=%d"
                          % (_n(lr.size_delta), _n(lr.transcript_grew), _n(lr.cpu_delta_cs),
                             cpu_tol_cs, lr.age_ms, freeze_ms, lr.window_ms))


def _n(v) -> str:
    """Render an optional number so an unread value is ``?``, never ``0``."""
    return "?" if v is None else str(v)


def evaluate(ev: Evidence) -> Verdict:
    """The verdict function. Pure: no I/O, no clock, no signals.

    ORDERING IS THE SAFETY PROPERTY, and this function's ordering is unchanged by
    the claim evidence: a claim is decided ONLY inside the existing empty-candidate
    branch (step 2's ``if not cands``), i.e. where the ladder had nothing to go on.
    A claim-bearing query that also carries a growing transcript still reads
    ``running-quiet/jsonl-grew``; a claim can never override session evidence and
    can never reach ``dead`` (see ``claim_verdict``).
    """
    # (0) THE LOG-LANE AXIS is a SEQUENTIAL ALTERNATIVE to the session ladder,
    #     never a parallel one. A log lane runs `pi -p --no-session`: it has no
    #     session id, no store record and no transcript, so the ladder below has
    #     nothing to read for it. Supplying BOTH kinds of evidence in one query is
    #     refused by name rather than silently letting the log read win — that
    #     would be the #1777 B7 defect (an added axis masking session evidence)
    #     reconstructed on a new axis.
    if ev.log_read is not None:
        # ⛔ THE REFUSAL IS ABOUT MASKING, NOT ABOUT `sid` SPECIFICALLY. Any other
        # evidence in the same query means the caller has a second axis's answer in
        # hand, and resolving silently to the log axis would DISCARD it — the
        # #1777 B7 shape. Naming the refusal beats picking a winner.
        # ⛔ AN ABSTENTION IS EVIDENCE TOO (T50). `ps_ok`/`store_ok` are the session
        # axis answering `unknown/ps-unreadable` / `unknown/store-unreadable`. This
        # guard once listed only the POSITIVE session fields, so a log read resolved
        # over a FAILED read — and a `frozen` log read then CONVICTED a lane on
        # evidence it had thrown away, which is strictly worse than the masking the
        # guard exists to stop.
        if ev.sid or ev.claim_read is not None or ev.candidates or ev.record is not None \
                or ev.jsonl_grew is not None or ev.jsonl_age_ms is not None \
                or ev.tool is not None or ev.jsonl_turn is not None \
                or not ev.ps_ok or not ev.store_ok:
            return Verdict(
                "unknown", "log-read-on-session-query",
                detail="a log-lane query carries ONLY log_read; supplying session or claim "
                       "evidence too would let this axis mask it (#1777 B7)")
        return log_lane_verdict(ev.log_read)

    # (1) Evidence availability. A failed read abstains with a NAMED reason —
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
            # #1777: a ref-claim read REFINES this abstention — it never precedes
            # the ladder, so no session verdict can be overridden by a claim.
            if ev.claim_read is not None:
                return claim_verdict(ev.claim_read)
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
        # nested `task` (T11, C8). The detail names the UNWRITTEN call the veto
        # is holding on (#5389 review cycle 1 P1): a report row that says only
        # `tool-in-flight` cannot distinguish the bash it is waiting on, and the
        # markdown-escape leg of the delivery suite needs the same
        # transcript-derived value the `wedged` row renders.
        held = ev.tool.call_label or ev.tool.name
        return Verdict("running-quiet", "tool-in-flight", holder_pid=holder.pid,
                       detail=("in-flight %s" % held) if held else "")

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
    except (OSError, ValueError):
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
    except (OSError, ValueError):
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
        except (OSError, ValueError):
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


# #5389 (a) — the fields are `builtin-tools`' wire names; the transcript's own
# keys are lowerCamel (`toolCall` / `toolCallId` / `stopReason`).
def _iso_ms(stamp) -> Optional[int]:
    """A session entry's ISO-8601 UTC `timestamp` as epoch ms, or None.

    Unparseable is None, never 0. Returning 0 would set `started = 0`, so the
    derived age becomes `now_ms - 0` — i.e. ~56 years — which EXCEEDS every
    backstop: the veto would be EXPIRED on a timestamp this parser could not
    read, and `evaluate` would be free to report `wedged` on unreadable evidence.
    That is the FAIL-OPEN direction. None is the fail-closed one: it propagates
    to `_exceeds`, which refuses to expire a veto on an unknown age, and the
    caller bounds it off the transcript's own mtime (#5389 review, cycle 2 F2).
    """
    if not isinstance(stamp, str) or not stamp:
        return None
    text = stamp[:-1] + "+00:00" if stamp.endswith("Z") else stamp
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return int(parsed.timestamp() * 1000)


def tool_from_jsonl(
    path: Optional[str],
    now_ms: int,
    silence_age_ms: Optional[int] = None,
) -> Optional[Tool]:
    """The in-flight tool, read from the session's OWN transcript (#5389 a).

    WHY THIS EXISTS. ``docs/ops/fleet-liveness.md`` §5 item 2 measured that
    ``_tool_from_record`` reads ``toolsInFlight``/``toolAgeMaxMs``/``streamAgeMs``
    /``toolUpdates`` off the cmux store record and **no store record carries
    them** — re-measured 2026-09-29: **0 of 1011**. So ``ev.tool`` was always
    ``None``, the veto never fired, and the transcript tail was the only
    open-turn signal. A fleet lane runs its tools in the SAME transcript this
    module already reads for its turn boundary, so the consumer that would make
    the veto live needs no new writer: an assistant message carrying tool calls
    with no ``toolResult`` after it IS a tool in flight.

    This is the wiring change §5 item 2 pre-authorised ("A consumer supplying the
    fields … would make it live — that is a wiring change, not a new rule"),
    and it is the cheapest of the two routes it names: no ``ps`` census, no CPU
    sampling, no process-tree walk. It is also the route
    ``docs/ops/pi-idle-repl-reaper-policy.md`` already sanctions — the LANE'S OWN
    pi session JSONL is the idle/quiet proof, and a child's is the child proof.

    ONLY TWO FIELDS ARE DERIVABLE, and the omissions are deliberate:

      * ``tool_updates`` ("this round produced RENDERABLE output") is NOT
        recoverable — pi persists no tool output before the tool ends, and a
        `toolResult` would mean the tool is no longer in flight. Left False.
      * ``cpu_advanced`` / ``cpu_stall_ms`` come from the task-child heartbeat
        (``extensions/task-heartbeat.ts``), which is gated to
        ``TASK_HEARTBEAT=1 AND PI_MODE=print`` and is silent in an interactive
        lane. Left False / 0.

    Both omissions push in the FAIL-CLOSED direction and neither is a silent
    hole: with ``tool_updates`` False and progress ``"unknown"``,
    ``tool_veto_expired`` takes the AGE backstop (4 h while the turn is active,
    30 min when it is not) instead of the 20 min silence bound. The veto
    therefore holds LONGER than ``tool-silence`` would, and the SAME as the
    ``tool-stall`` backstop the watchdog itself applies to a tool with no
    readable CPU channel — it never stands quiet where the watchdog had already
    cut, and it is always bounded (T9: never forever).

    ``turn_active`` is the one field the transcript cannot supply, and it is
    set True — the fail-CLOSED choice, which selects the 4 h backstop rather
    than the 30 min one (a lane whose transcript shows an unanswered call is by
    definition not resting).

    The derived age is bounded from TWO sources, not one. The transcript's own
    mtime is a genuine lower bound on the call's age (the file is written at or
    after the call), so ``min(started, mtime)`` covers both shapes an entry
    stamp alone cannot: an UNREADABLE stamp (age would be unknown → an unknown
    age never expires) and a FUTURE-dated stamp from a writer host on a bad
    clock (a bare ``now - started`` clamps to 0 and STAYS 0 → the 4 h backstop
    is never reached). Both are the permanent veto T9 forbids (#5389 review F2).

    Returns None — never a zeroed Tool — when the tail shows no in-flight tool:
    a ``None`` veto and an empty one are different claims, and manufacturing the
    empty one would assert "no tool is running" from a transcript this parser
    simply could not read. A ``length``-truncated message is one such shape on
    the OTHER side of the boundary: it is OPEN (pi continues the turn) but its
    calls were FAILED, not executed, so it asserts no tool either — see
    ``CALL_FAILED_STOP_REASONS`` (#5389 review, cycle 4, P2).
    """
    if not path:
        return None
    entry, last_entry, _size = _last_message_entry(path)
    # Mirror turn_from_jsonl: a compaction trailer decides neither disposition.
    if (last_entry is not None and isinstance(last_entry, dict)
            and last_entry.get("type") == "compaction"):
        return None
    if not isinstance(entry, dict):
        return None
    msg = entry.get("message")
    if not isinstance(msg, dict) or msg.get("role") != "assistant":
        return None
    calls = [item for item in (msg.get("content") or [])
             if isinstance(item, dict) and item.get("type") == "toolCall"]
    if not calls:
        return None
    # A call-carrying message whose stop reason DISCARDS its calls is not an
    # in-flight tool (`turn_from_entry` decides the same way, so the veto and
    # the boundary cannot disagree about whether this message is open).
    if msg.get("stopReason") in CALL_DISCARDING_STOP_REASONS:
        return None
    # #5389 review (cycle 4, P2): `length` FAILS the truncated message's calls
    # (`failToolCallsFromTruncatedMessage`) while the turn stays OPEN. The veto
    # is about a tool EXECUTING, and no call here is — asserting one would
    # suppress the honest `wedged` verdict for a lane pi hung on immediately
    # after truncating.
    if msg.get("stopReason") in CALL_FAILED_STOP_REASONS:
        return None
    # The transcript's OWN mtime, read once and used for BOTH bounds below. It
    # is a genuine lower bound on the call's age: the file is written at or
    # after the call, so the call is at least as old as the file.
    try:
        mtime_ms = int(os.stat(path).st_mtime * 1000)
    except (OSError, ValueError):
        mtime_ms = None
    started = _iso_ms(entry.get("timestamp"))
    if started is None:
        # #5389 review P1: an UNREADABLE entry stamp must not leave the age
        # UNKNOWN. A derived tool is `"unknown"` by construction (no CPU
        # channel), so the AGE backstop is the only bound it can reach — and
        # `_exceeds(None, bound)` is deliberately False, which would make the
        # veto PERMANENT: the lane would read `running-quiet/tool-in-flight`
        # forever and `idle` would become unreachable, which is the one outcome
        # T9 forbids. Fall back to the transcript's OWN mtime: it is a genuine
        # measurement and it grows without bound while the file is frozen, so
        # the veto still expires.
        if mtime_ms is None:
            # Cannot date the call from ANY source. Do NOT return a Tool here:
            # `_exceeds(None, bound)` is False, so an unmeasurable age makes the
            # veto PERMANENT (T9 forbids it — and that is the defect the previous
            # line's fallback exists to avoid). Returning None is bounded AND
            # safe rather than fail-open: a stat failure here is a stat failure
            # in `jsonl_state` too, so `gather` carries `jsonl_age_ms=None` and
            # `evaluate` names that `jsonl-age-unknown` — an ABSTENTION reached
            # after the (now absent) veto, never `wedged`. (#5389 review, cycle 3.)
            return None
        started = mtime_ms
    elif mtime_ms is not None:
        # #5389 review F2: a FUTURE-dated entry stamp (a writer host with a
        # wrong clock — a VM booting on a bad RTC before NTP corrects it) makes
        # `now - started` clamp to 0 and STAY 0 while the stamp is ahead of the
        # clock, so the 4 h AGE backstop is never reached and the veto is
        # PERMANENT (`idle` unreachable) — the same outcome T9 forbids by
        # another route. `min` takes the EARLIER timestamp, which never reports
        # the call as younger than it is, so the veto can only expire no earlier
        # than the call's true age allows.
        started = min(started, mtime_ms)
    age = max(0, now_ms - started)
    return Tool(
        name=str(calls[0].get("name") or ""),
        call_label=", ".join(_tool_call_labels(msg)),
        tools_in_flight=len(calls),
        tool_updates=False,
        silence_age_ms=silence_age_ms,
        tool_age_ms=age,
        cpu_advanced=False,
        cpu_stall_ms=0,
        turn_active=True,
    )


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
        except (OSError, ValueError):
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
    if tool is None:
        # #5389 (a): no store record carries the watchdog's tool fields (measured
        # 0 of 1011, 2026-09-29), so the record path is authoritative ONLY when a
        # producer actually supplies them. Otherwise the lane's OWN transcript is
        # the producer — the consumer that makes the already-built veto live.
        tool = tool_from_jsonl(sfile, now, silence_age_ms=age)
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


def _proc_cpu_cs(root: str = "/proc") -> Optional[Dict[int, Tuple[int, Optional[int]]]]:
    """``{pid: (ppid, cpu_cs)}`` read from ``/proc`` at ``SC_CLK_TCK`` resolution.

    ⛔ WHY NOT JUST ``ps -o time=``: **GNU procps prints whole seconds only.**
    Measured on this host (procps-ng 4.0.4): a process holding 65 ticks (0.65 s) of
    CPU prints ``00:00:00``, and one holding 1.2 s prints ``00:00:01``. So the
    ``LOG_CPU_TOL_CS`` = 10 cs (0.10 s) tolerance is UNREACHABLE through ``ps`` on
    Linux and the real floor there is 1.0 CPU-second per window — a lane burning
    under ~3 % of a core would read flat. ``/proc/<pid>/stat`` carries
    ``utime``+``stime`` in clock ticks (``SC_CLK_TCK`` = 100 Hz on every Linux these
    cells run), i.e. true centiseconds, which is the resolution this axis claims.

    Returns ``None`` when ``/proc`` is not readable (macOS) so the caller falls back
    to ``ps``; a pid that vanishes mid-walk is simply absent (it is gone).

    ``root`` is injectable ONLY so the malformed-row arm below can be driven from a
    synthetic tree: ``/proc`` does not exist on the Mac, so without a seam that arm had
    no test at all and it shipped encoding an unreadable row as ``(0, None)``.
    """
    try:
        names = os.listdir(root)
    except (OSError, ValueError):
        return None
    out: Dict[int, Tuple[int, Optional[int]]] = {}
    for name in names:
        if not name.isdigit():
            continue
        try:
            raw = open(os.path.join(root, name, "stat"), "rb").read().decode("utf-8", "replace")
        except (OSError, ValueError):
            continue
        # `comm` may contain spaces and parentheses: split on the LAST ')'
        close = raw.rfind(")")
        if close < 0:
            # ⛔ A ROW WITH NO `)` IS MALFORMED, NOT VANISHED (review P2, same rule as the
            # parse arm below). `open()` succeeded, so the pid still existed when it was
            # read; the content simply is not a `stat` line. Skipping it drops its CPU from
            # the total — a SMALLER total, which reads as flat and then `frozen`. A process
            # that truly vanished is the `OSError` arm above, which is the only arm here
            # that is allowed to `continue`.
            return None
        rest = raw[close + 2:].split()
        # rest[0] = state (field 3), so field N is rest[N-3]
        try:
            ppid = int(rest[1])           # field 4
            utime = int(rest[11])         # field 14
            stime = int(rest[12])         # field 15
        except (IndexError, ValueError):
            # ⛔ AN UNPARSEABLE ROW ABSTAINS THE WHOLE READ — IT IS NOT ENCODED AS `(0, None)`
            # (review P2). `(0, …)` re-parents the pid to 0, so the walk from our root NEVER
            # REACHES IT: `kids[root]` does not contain it, `cpu.get(p) is None` never fires, and
            # its CPU silently leaves the total — a SMALLER total, which is exactly how a busy
            # tree reads flat and then `frozen`, the failure `_sum_subtree`'s docstring forbids.
            # Encoding it also orphans its own descendants, which hang off a pid nobody visits.
            # The `ps` arm below already does the right thing for this same shape (`return None`
            # on `len(parts) < 3`); this arm now matches it instead of being the one path that
            # turns an unread member into a missing one.
            return None
        out[int(name)] = (ppid, (utime + stime) * 100 // _CLK_TCK)
    return out or None


# `sysconf(_SC_CLK_TCK)` is 100 on every Linux the fleet runs; read it when we can so
# an exotic kernel cannot silently rescale the signal.
def _clk_tck() -> int:
    try:
        return int(os.sysconf("SC_CLK_TCK")) or 100
    except (ValueError, OSError, AttributeError):
        return 100


_CLK_TCK = _clk_tck()


def subtree_cpu_cs(pid: int, *, ps_bin: Optional[str] = None) -> Optional[int]:
    """Cumulative CPU of ``pid`` **and every descendant**, in centiseconds.

    S2 of the progress contract. ``None`` on any unreadable read — an unread
    signal must abstain, never read as flat (which would convict a live lane).

    **Resolution, measured:** ``/proc`` (Linux) gives ``SC_CLK_TCK`` = 100 Hz, i.e.
    **1 cs**; GNU ``ps -o time=`` gives WHOLE SECONDS (measured, procps-ng 4.0.4: 0.65 s
    of CPU prints ``00:00:00``), and BSD/macOS ``ps`` gives ``MM:SS.cc``. So the Linux
    path is used wherever it exists and the resolution this axis claims is only true
    there — see ``docs/ops/fleet-liveness.md`` §13.3, which states both floors rather
    than the better one.

    The tree is walked from the parent map, so a wrapper-then-`pi` launch costs the
    same as an `exec`-ed one. This is the same reading `lane-bound.sh` samples twice,
    expressed once.
    """
    # Linux: /proc, at real centisecond resolution. BSD/macOS has no /proc, so the
    # `ps` walk below is the fallback (there `time=` carries `.cc`).
    proc = _proc_cpu_cs() if ps_bin is None else None
    if proc is not None:
        return _sum_subtree(pid, {p: v[0] for p, v in proc.items()},
                            {p: v[1] for p, v in proc.items()})
    ps = ps_bin or os.environ.get("PS_BIN") or "ps"
    try:
        out = subprocess.run([ps, "-axo", "pid=,ppid=,time="],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=60).stdout.decode("utf-8", "replace")
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    if not out.strip():
        return None
    ppid: Dict[int, int] = {}
    cpu: Dict[int, Optional[int]] = {}
    for line in out.splitlines():
        parts = line.split()
        if not parts:
            continue  # a blank line carries no row
        # ⛔ A MALFORMED ROW IS NOT SKIPPED. Whether it belongs to OUR subtree is only
        # decidable after the walk, and skipping it makes the total SMALLER — which is
        # how a busy tree reads flat and then `frozen`.
        if len(parts) < 3:
            return None
        try:
            p = int(parts[0])
            par = int(parts[1])
        except ValueError:
            return None
        ppid[p] = par
        cpu[p] = _cpu_time_cs(parts[2])   # None = an unread member; the walk abstains
    return _sum_subtree(pid, ppid, cpu)


def _sum_subtree(pid: int, ppid: Dict[int, int],
                 cpu: Dict[int, Optional[int]]) -> Optional[int]:
    """Sum ``cpu`` over ``pid`` and every descendant. ``None`` if any member is unread.

    ⛔ AN UNREAD MEMBER ABSTAINS THE WHOLE TOTAL. Skipping it makes the total
    SMALLER, and a smaller total is how a busy tree reads flat → ``frozen``. Whether a
    row belongs to OUR subtree is only decidable after the walk, which is why the
    check lives here rather than at the parse.
    """
    if pid not in cpu:
        return None
    kids: Dict[int, List[int]] = {}
    for p, par in ppid.items():
        kids.setdefault(par, []).append(p)
    total = 0
    stack = [pid]
    seen = set()
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        if cpu.get(p) is None:
            return None
        total += cpu[p] or 0
        stack.extend(kids.get(p, ()))
    return total



def _cpu_time_cs(text: str) -> Optional[int]:
    """``[[dd-]hh:]mm:ss[.cc]`` → centiseconds. ``None`` when the shape is unexpected.

    ⛔ BOTH PLATFORMS' SPELLINGS ARE REQUIRED. GNU ``ps`` prints ``mm:ss`` /
    ``hh:mm:ss``; **BSD/macOS prints ``MM:SS.cc``** (``0:00.50``) and
    ``HH:MM:SS.cc`` — and the Mac is the host where `cmux.app` fleet ancestry (and
    therefore the fleet's lanes) actually lives, so rejecting the fractional form
    would make S2 permanently unreadable there. This is the same grammar
    ``scripts/orchestrator-harness/lane-reap.sh``'s ``cs()`` parses.
    """
    days = 0
    body = text.strip()
    if "-" in body:
        d, _, body = body.partition("-")
        if not (d.isascii() and d.isdigit()):
            return None
        days = int(d)
    frac = 0
    if "." in body:
        body, _, f = body.partition(".")
        if not (f.isascii() and f.isdigit()):
            return None
        frac = int((f + "00")[:2])
    fields = body.split(":")
    # `.isdigit()` admits non-ASCII digits (`\u00b2`), which `int()` then REJECTS —
    # so the guard passed and the parse raised, where this function's contract is
    # `None` on an unreadable read (and `subtree_cpu_cs` promises the same).
    if not 1 <= len(fields) <= 3 or not all(f.isascii() and f.isdigit() for f in fields):
        return None
    vals = [int(f) for f in fields]
    if len(vals) == 1:
        hh = mm = 0
        ss = vals[0]
    elif len(vals) == 2:
        hh = 0
        mm, ss = vals
    else:
        hh, mm, ss = vals
    if ss >= 60 or mm >= 60:
        return None
    return ((days * 24 + hh) * 3600 + mm * 60 + ss) * 100 + frac


def gather_log_lane(
    log_path: str,
    pid: int,
    *,
    start_seconds: Optional[int] = None,
    transcript: Optional[str] = None,
    verdict_file: Optional[str] = None,
    lib: Optional[str] = None,
    now_ms: Optional[int] = None,
    window_ms: int = LOG_WINDOW_MS,
    sample: bool = True,
    sleep_fn: Optional[Callable[[float], None]] = None,
) -> LogRead:
    """Acquire the evidence for a LOG LANE (the I/O half; the verdict is pure).

    ``sample`` takes the second reading of both progress signals across
    ``window_ms``. Tests pass ``sample=False`` and inject deltas, so the suite
    never sleeps.

    ⛔ The process probe is the fleet's ONE identity rule
    (``scripts/lib/pid-identity.sh``), exactly as ``collect_candidates`` uses it.
    A presence-only probe would be a SECOND identity rule — the defect #1178
    exists to remove — so an unfenceable pid (no start time to compare) reads
    ``alive=None`` and the axis ABSTAINS rather than inventing a liveness fact.
    """
    now = int(now_ms if now_ms is not None else time.time() * 1000)
    lr = LogRead(path=log_path, window_ms=window_ms)

    # S1, reading 1 (+ the mtime age, which is REPORTED only).
    try:
        st = os.stat(log_path)
    except FileNotFoundError:
        lr.present = False
        lr.readable = False
        lr.detail = "absent:%s" % log_path
    except (OSError, ValueError) as exc:
        lr.present = True
        lr.readable = False
        lr.detail = "unreadable:%s (%s)" % (log_path, exc)
    else:
        lr.present = True
        # ⛔ A PATH THAT STATS BUT IS NOT A REGULAR FILE IS NOT A READABLE LOG. A
        # directory (or a fifo, or a socket) stats fine, reports a size, and never
        # yields bytes — so `st_size` would make an UNREADABLE log look readable and
        # a 0-byte delta on it would read as "flat".
        if not stat.S_ISREG(st.st_mode):
            lr.readable = False
            lr.detail = "not-a-regular-file:%s mode=%o" % (log_path, st.st_mode)
        else:
            lr.readable = True
            lr.size = int(st.st_size)
            lr.age_ms = max(0, int(now - st.st_mtime * 1000))

    # The verdict the supervisor writes. The FILE is preferred (it is the
    # programmatic surface); the log's own tail is the fallback, because a lane
    # launched without `--verdict-file` still prints it.
    if verdict_file:
        try:
            with open(verdict_file, "r", encoding="utf-8", errors="replace") as fh:
                raw = fh.read()
        except (OSError, ValueError):
            raw = ""
        v, rc = parse_bound_line(raw)
        if v:
            lr.verdict, lr.rc, lr.verdict_source = v, rc, "verdict-file"
            # ⛔ THE FILE IS BOUND EXACTLY LIKE THE TAIL. Leaving this unset made the
            # file arm the one unbound door: its verdict was adopted while the detail
            # claimed `bound-verdict-without-pid` about a line that DID carry a pid —
            # so a `$log.lanebound` left by an earlier dispatch was still a false PASS,
            # and it outranked the fresh bound tail (this arm runs first).
            lr.verdict_line_pid = parse_bound_pid(raw)

    # No file verdict (or no file at all): the tail is the programmatic fallback, because
    # a lane launched without `--verdict-file` still PRINTS its verdict.
    if not lr.verdict and lr.readable:
        tail = _log_tail(log_path)
        v, rc = parse_bound_line(tail)
        if v:
            lr.verdict, lr.rc, lr.verdict_source = v, rc, "log"
            lr.verdict_line_pid = parse_bound_pid(tail)

    # ⛔ BIND THE VERDICT TO THE INCARNATION BEING ASKED ABOUT. The log is appended to
    # across dispatches, and a `--verdict-file` from an earlier run can survive too, so
    # an unbound verdict is a PREVIOUS dispatch's outcome. The line's `pid=` is
    # `lane-bound.sh`'s own `${PID}`, which in `run` mode is the CHILD it supervised —
    # not necessarily the tree root the caller asked about — so the test is "equal OR
    # verified inside the queried tree", and an UNVERIFIABLE binding drops the verdict.
    # Dropping it yields `no-verdict` (never `finished`, never `dead`): the
    # over-refusal direction, which is the only acceptable one here.
    def _bind():
        return _bind_verdict(lr, int(pid))

    if lr.verdict:
        why, note = _bind()
        if why and lr.verdict_source == "verdict-file":
            # ⛔ A DROPPED FILE VERDICT MUST NOT BLOCK THE LANE'S OWN. The file is read
            # first, so without this fall-through a stale `$log.lanebound` would suppress
            # the fresh, correctly-bound line in the log's own tail.
            lr.verdict, lr.rc, lr.verdict_line_pid = "", None, ""
            if lr.readable:
                tail = _log_tail(log_path)
                v, rc = parse_bound_line(tail)
                if v:
                    lr.verdict, lr.rc, lr.verdict_source = v, rc, "log"
                    lr.verdict_line_pid = parse_bound_pid(tail)
                    why, note = _bind() if lr.verdict else (why, note)
        if note:
            lr.detail = " | ".join(x for x in (lr.detail, note) if x)
        if why:
            lr.detail = " | ".join(x for x in (lr.detail, why) if x)
            lr.verdict, lr.rc = "", None

    # ⛔ CORROBORATE `rc=na` FROM THE LAUNCHER'S OWN LINE. `na` is `watch` mode's
    # unconditional shape (`lane-bound.sh:397`) and the fleet ALWAYS uses `watch`
    # (`spawn-gate.sh:1532`), so it carries no completion fact — see `BOUND_OK_RC`. The
    # child's real status is written to the SAME log by the caller as
    # `[timeout] agent pid=<pid> … rc=<n>` (`spawn-gate.sh:1583`). Read it here, and
    # accept it only when it names THIS verdict's incarnation — a leftover line from an
    # earlier dispatch appended to the same log is not this lane's exit status.
    if lr.rc == "na" and lr.readable:
        runner_pid, runner_rc = parse_runner_line(_log_tail(log_path))
        if runner_rc is not None:
            same_incarnation = ((runner_pid == lr.verdict_line_pid)
                                if lr.verdict_line_pid else (runner_pid == str(pid)))
            if same_incarnation:
                lr.runner_rc = runner_rc
            else:
                lr.detail = " | ".join(x for x in (
                    lr.detail,
                    "runner-rc-unbound bound_pid=%s runner_pid=%s"
                    % (lr.verdict_line_pid or "?", runner_pid)) if x)

    # S2, reading 1.
    cpu0 = subtree_cpu_cs(pid)
    if cpu0 is None:
        lr.cpu_unreadable = True

    # S1b, reading 1 — the transcript's size, when the lane HAS one.
    tsize0 = _size_or_none(transcript) if transcript else None

    if sample and lr.readable:
        (sleep_fn or time.sleep)(max(0.0, window_ms / 1000.0))
        cpu1 = subtree_cpu_cs(pid)
        if cpu0 is None or cpu1 is None:
            lr.cpu_unreadable = True
            lr.cpu_delta_cs = None
        elif cpu1 < cpu0:
            # ⛔ A NEGATIVE DELTA IS NOT "FLAT". A stable subtree cannot LOSE CPU, so a
            # negative delta means one of the two reads was incomplete (a child exited
            # between the samples, a truncated /proc or `ps` read, a root row that
            # vanished mid-stream). Reading it as "no progress" hands the decision to
            # the log age alone and freezes a lane that may be working — the identical
            # rule `lane-reap.sh` states for its own two-sample CPU gate ("the reading
            # is broken, so the answer is an abstention, never the code's most
            # permissive value"). Measured with real `ps`: a silent tool loop spawning
            # short-lived CPU children read -200 cs on 2 of 5 trials.
            lr.cpu_unreadable = True
            lr.cpu_delta_cs = None
        else:
            lr.cpu_delta_cs = cpu1 - cpu0
        try:
            lr.size_delta = int(os.stat(log_path).st_size) - int(lr.size or 0)
        except (OSError, ValueError):
            lr.readable = False
            lr.detail = "unreadable-on-second-read:%s" % log_path
        if tsize0 is not None:
            tsize1 = _size_or_none(transcript)
            if tsize1 is not None:
                lr.transcript_grew = tsize1 > tsize0

    # IDENTITY. `probe_pid` is the fleet's ONE identity rule — the fenced `probe`
    # subcommand, never the presence-only `probe-argv` (which answers `holder` for
    # ANY live pid and is therefore a second identity rule). That fence needs the
    # process's start time, so a caller that does not supply one gets an
    # ABSTENTION (`process-identity-unreadable`) rather than a presence-only guess.
    res = probe_pid(pid, start_seconds, lib=lib)
    observed = observed_from_probe(res.rc, res.status)
    if observed in WITNESS_OBSERVED:
        lr.alive = False
    elif observed == HOLDER:
        lr.alive = True
    else:
        lr.alive = None
        lr.detail = " | ".join(x for x in (
            lr.detail, "probe rc=%d status=%s" % (res.rc, res.status or "?")) if x)
    return lr


def _size_or_none(path: Optional[str]) -> Optional[int]:
    if not path:
        return None
    try:
        return int(os.path.getsize(path))
    except (OSError, ValueError):
        return None


def _log_tail(path: str, limit: int = 8192) -> str:
    """The log's last ``limit`` bytes — bounded, so a multi-MB log is never read whole."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > limit:
                fh.seek(size - limit)
            return fh.read().decode("utf-8", "replace")
    except (OSError, ValueError):
        return ""


def _updated_at(val) -> Optional[float]:
    try:
        return float(val)
    except (TypeError, ValueError):
        return None


def _tool_from_record(rec: dict) -> Optional[Tool]:
    """The store record's tick fields, when a producer supplies them.

    No producer does today (measured 2026-09-29: **0 of 1011** records carry
    ``toolsInFlight``), which is why :func:`gather` falls back to
    :func:`tool_from_jsonl`. This route stays authoritative when it IS supplied,
    because it carries two fields the transcript cannot: ``toolUpdates`` (the
    round produced renderable output) and the ``cpuAdvanced`` / ``cpuStallMs``
    pair from the task-child heartbeat.

    Absent fields stay ``None``/False, which keeps the tool veto in place
    (fail-closed: quiet is never a stall).
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
def _log_lane_cli(argv: Sequence[str]) -> Optional[int]:
    """``--log`` / ``--log-census``: the LOG-LANE axis's command surface.

    Two shapes, and they answer different questions:

      ``--log <file> --pid <pid>``   one lane, sampled over ``--window-ms``
      ``--log-census``              MANY lanes, stdin ``pid\\tlog\\tsize_delta\\tcpu_delta_cs\\tverdict\\talive\\tage_ms\\tbytes\\ttranscript_grew\\trc[\\tverdict_pid]``
                                    (``?`` or empty = NOT READ = abstain) — the deltas
                                    come FROM THE CALLER, because a census that judged 76
                                    lanes must not sleep 30 s per lane; the caller
                                    already owns the two samples.

    Both publish the same states, from the same function. This is a seam, never a
    second classifier: there is no state decided here that
    :func:`log_lane_verdict` does not decide.
    """
    log = pid = vfile = transcript = None
    start_seconds = None
    window_ms = LOG_WINDOW_MS
    sample = True
    as_json = False
    census = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--log" and i + 1 < len(argv):
            log = argv[i + 1]; i += 2; continue
        if a == "--pid" and i + 1 < len(argv):
            try:
                pid = int(argv[i + 1])
            except ValueError:
                print("liveness.py: --pid must be an integer", file=sys.stderr)
                return 2
            i += 2; continue
        if a == "--verdict-file" and i + 1 < len(argv):
            vfile = argv[i + 1]; i += 2; continue
        if a == "--transcript" and i + 1 < len(argv):
            transcript = argv[i + 1]; i += 2; continue
        if a == "--start-seconds" and i + 1 < len(argv):
            try:
                start_seconds = int(argv[i + 1])
            except ValueError:
                print("liveness.py: --start-seconds must be an integer", file=sys.stderr)
                return 2
            i += 2; continue
        if a == "--window-ms" and i + 1 < len(argv):
            try:
                window_ms = int(argv[i + 1])
            except ValueError:
                print("liveness.py: --window-ms must be an integer", file=sys.stderr)
                return 2
            # ⛔ A ZERO-LENGTH WINDOW CANNOT PRODUCE A DELTA. It collapses both readings
            # into one instant, so both progress signals are trivially flat and a LIVE,
            # working lane reads `frozen` — measured end to end with a CPU burner.
            if window_ms < 1:
                print("liveness.py: --window-ms must be >= 1 (a zero-length window cannot "
                      "produce a delta)", file=sys.stderr)
                return 2
            i += 2; continue
        if a == "--no-sample":
            sample = False; i += 1; continue
        if a == "--json":
            as_json = True; i += 1; continue
        if a == "--log-census":
            census = True; i += 1; continue
        print("liveness.py: unrecognised argument %r" % a, file=sys.stderr)
        return 2

    if census:
        if log or pid is not None:
            print("liveness.py: --log-census reads its lanes from stdin; "
                  "do not also pass --log/--pid", file=sys.stderr)
            return 2
        rc = 0
        for line in sys.stdin:
            line = line.rstrip("\n")
            if not line:
                continue
            f = line.split("\t")

            # ⛔ EVERY FIELD IS DECODED BY A STRICT ALLOW-LIST, BECAUSE A LOOSE ONE IS A
            # DEATH WITNESS. `alive == (token == "1")` read any unrecognised token as a
            # POSITIVE `False` — i.e. a typo, a future spelling or a stray `2` would
            # manufacture "the process is gone" and publish `no-verdict` over a live
            # lane. Anything outside the allow-lists is `None` = NOT READ = abstain,
            # which is the whole doctrine. `?` (and an absent field) is NOT 0 either.
            def _opt(idx):
                if idx >= len(f) or f[idx] in ("", "?"):
                    return None
                try:
                    return int(f[idx])
                except ValueError:
                    return None

            def _tri(idx):
                if idx >= len(f):
                    return None
                tok = f[idx].strip().lower()
                if tok in ("1", "true", "yes"):
                    return True
                if tok in ("0", "false", "no"):
                    return False
                return None  # "", "?", "2", "gone" … — NOT READ

            verdict = f[4] if len(f) > 4 and f[4] in BOUND_VERDICTS else ""
            # ⛔ `int("?")` RAISES, AND `"\u00b2".isdigit()` IS TRUE WHILE `int("\u00b2")`
            # IS NOT. The census's own "not read" token is `?`, so a row whose pid column
            # was `?` aborted the WHOLE run with a traceback after printing only the rows
            # before it (measured: `?\t<log>\t0\t?\tfinished\t...` -> ValueError, rc=1).
            def _pidtok(tok):
                return (tok if tok.isascii() and tok.isdigit() and len(tok) <= 10
                        else "")

            def _num(idx):
                return _pidtok(f[idx].strip() if idx < len(f) else "")

            def _pidcol(idx):
                # ⛔ "" IS "COLUMN ABSENT"; "?" IS "PRESENT BUT UNUSABLE". Collapsing
                # the two (`_num` did) made a PRESENT-but-unreadable column 11 fall into
                # the `else:` arm below — the one that ADOPTS an unbound verdict and says
                # so — so a caller following the census's own documented "NOT READ"
                # convention (`?`) had a previous dispatch's `finished` published, while
                # `gather_log_lane` DROPPED the identical token. Same rule, same three
                # outcomes, or the seam is the fail-open door.
                if idx >= len(f):
                    return ""
                return _pidtok(f[idx].strip()) or "?"

            verdict_pid = _pidcol(10)
            row_pid = _num(0)
            path = f[1] if len(f) > 1 else ""
            lr = LogRead(path=path, size_delta=_opt(2), cpu_delta_cs=_opt(3),
                         window_ms=window_ms, verdict=verdict,
                         rc=(f[9] if len(f) > 9 and f[9] not in ("", "?") else None),
                         verdict_line_pid=verdict_pid,
                         verdict_source="caller" if verdict else "")

            # ⛔ THE CENSUS MUST ENFORCE THE BINDING TOO, OR IT IS THE FAIL-OPEN DOOR.
            # Column 5 is only a token; without the line's own pid a caller that just
            # parsed `verdict=finished` out of an APPENDED log publishes a previous
            # dispatch's outcome here, on the surface §13.5 names as the fleet reader's
            # home. Same rule as `gather_log_lane`, same three outcomes.
            # An UNREADABLE row pid is not freedom either: with no pid to bind to, the
            # verdict is dropped (fail-closed), exactly as an unverifiable `verdict_pid`.
            # And an adopted-but-unbound row now DECLARES itself, the fifth rule.
            if lr.verdict:
                if not row_pid or row_pid == "?":
                    # No readable pid to bind TO: the verdict cannot be attributed at
                    # all, so it is dropped (fail-closed).
                    why, note = ("unbound-bound-verdict query_pid=? source=census", "")
                elif verdict_pid:
                    # ⛔ `?` MEANS COLUMN 11 WAS PRESENT AND UNRESOLVABLE, and it is routed
                    # through `_bind_verdict` (which drops it) rather than to the adopt arm
                    # below. Those are different rows: `?` is the census's own not-read
                    # token, and adopting it publishes a verdict whose binding was never
                    # checked — the fail-open this block exists to close.
                    why, note = _bind_verdict(lr, int(row_pid))
                else:
                    # Column 11 absent — the documented 10-column row. §13's table's
                    # fifth rule: ADOPT it and DECLARE it unbound.
                    why = None
                    note = "bound-verdict-without-pid source=census"
                if note:
                    lr.detail = " | ".join(x for x in (lr.detail, note) if x)
                if why:
                    lr.detail = " | ".join(x for x in (lr.detail, why) if x)
                    lr.verdict, lr.rc = "", None
            # ⛔ THE SEAM MUST NOT ASSERT THAT A LOG IS READABLE. Decoding `alive`,
            # `verdict` and `rc` strictly while hard-coding `readable=True` made an
            # ABSENT or DELETED log publish a state (`frozen`, or `dead` when the row
            # also carried a verdict) instead of the contract-4 abstention — and a
            # deleted-but-held log is a shape this tree explicitly models (`lane-reap.sh`
            # `_log_candidate`'s `del=1` arm). One stat per row; no sleep.
            if len(f) < 2 or path in ("", "-"):
                lr = LogRead()  # no resolvable log is an ABSTENTION, never death
            else:
                try:
                    st = os.stat(path)
                except (OSError, ValueError) as exc:
                    lr.readable = False
                    lr.detail = "unreadable:%s (%s)" % (path, exc.__class__.__name__)
                else:
                    if stat.S_ISREG(st.st_mode):
                        lr.readable = True
                        lr.present = True
                    else:
                        lr.readable = False
                        lr.present = True
                        lr.detail = "not-a-regular-file:%s" % path
                lr.alive = _tri(5)
                lr.age_ms = _opt(6)
                lr.size = _opt(7)
                lr.transcript_grew = _tri(8)
            v = evaluate(Evidence(log_read=lr))
            if v.state == "unknown":
                rc = 3
            print("\t".join([f[0] if f else "?", v.state, v.reason, v.detail or ""]))
        return rc

    if not log or pid is None:
        print("liveness.py: --log and --pid are both required for a log-lane query",
              file=sys.stderr)
        return 2
    lr = gather_log_lane(log, pid, start_seconds=start_seconds, transcript=transcript,
                         verdict_file=vfile, window_ms=window_ms, sample=sample)
    verdict = evaluate(Evidence(log_read=lr))
    if as_json:
        print(json.dumps(verdict.to_dict(), sort_keys=True))
    else:
        print("%s %s%s" % (verdict.state, verdict.reason,
                           "" if not verdict.detail else " " + verdict.detail))
    return 0 if verdict.state != "unknown" else 3


def main(argv: Optional[Sequence[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if any(a in ("--log", "--log-census") for a in argv):
        return _log_lane_cli(argv)
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
        print("usage: liveness.py --sid <session-id> [--store PATH] [--sessions-dir DIR] [--json]\n"
              "       liveness.py --log <file> --pid <pid> [--start-seconds N] [--verdict-file F]\n"
              "                   [--transcript T] [--window-ms N] [--no-sample] [--json]\n"
              "       liveness.py --log-census  < pid\\tlog[\\tsize_delta\\tcpu_delta_cs\\tverdict\\talive\\tage_ms\\tbytes\\ttranscript_grew\\trc[\\tverdict_pid]]",
              file=sys.stderr)
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
