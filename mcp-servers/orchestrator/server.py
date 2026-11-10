#!/usr/bin/env python3
"""Orchestrator MCP server — the typed façade over the harness's own tools (#3382).

WHAT THIS IS, IN ONE PARAGRAPH
------------------------------
Eleven tools, expressed as **twelve MCP names**: `lane.list` / `lane.show` (extended with the liveness
axis, the `finished`/`dead` mapping and the tree recursion) plus ten new names. Every one of them is a
WRAPPER over an implementation that already exists in this repo, and the mapping is
`docs/ops/orchestrator-mcp-inventory.md` §5.10 — not a re-description of it. The server adds typing, one
stable name, the `UNMEASURED(<cmd> + <error>)` contract, and `instrument_versions()`. **No tool re-derives
another module's answer**, and where a module cannot answer the tool's own signature (a repo parameter, a
`--json` payload) the missing half was written *into that module*, once.

    lane.list             every lane the fleet has a STATE RECORD for (+ liveness axis, + tree)
    lane.show             one lane, or NOT-FOUND (a lookup outcome, never a state)
    lane.artifact         one lane's WORK IN PROGRESS (words) and its artifacts on a box (files)
    fleet.census          a repo-parameterised census: P0/P1 open·with-PR·NONE + box capacity, timestamped
    pr.queue              per-PR actions (15 answers), mapped to the issue's 6 classes as a VIEW
    claim.check           the ref-claim registry: abstention vocabulary ONLY, never freedom
    lane.dispatch         launch one lane; typed refusals, never stderr prose
    box.exec              {rc, stdout, timed_out, truncated} over `cmux vm exec`, argv-only, allowlisted
    pr.review_record      current | stale | absent + the head the record is bound to
    pr.closure_audit      what a merge ACTUALLY closed, vs what it merely mentioned
    fleet.reminder        set/list/cancel a durable reminder (file-backed queue + timer lifecycle)
    fleet.beat_checkpoint the durable cycle record: `report.sh` (read) + `cycle-record.sh`'s verdict

⛔ ANNOTATIONS ARE DECLARED FOR EVERY TOOL, ALL FOUR OF THEM. The MCP spec's defaults are pessimistic — an
unannotated tool is treated as destructive, non-idempotent and open-world — so "omitted" is not a neutral
choice, it is the worst available reading. The spec's own example for `openWorldHint: true` is "a shell
command", which is `box.exec` precisely. Annotations are HINTS (clients MUST treat them as untrusted), so
they never replace a control: `box.exec`'s allowlist and argv surface are the control.

⛔ `box.exec` TAKES AN ARGV ARRAY. NEVER A SHELL STRING, NEVER `sh -lc`. Claude Code's own security docs
record that a deny/allow rule "doesn't match the same program by path or inside `sh -c`" — so a text-matching
allowlist over a shell string is defeated by the shell itself, and an argv surface is what makes the
allowlist real. Fail-closed: a command not on the allowlist is a **typed refusal**, never a pass-through.

READ-ONLY BY DEFAULT IS A FLAG, NOT A PROMISE
---------------------------------------------
`--read-only` (or `ORCH_MCP_READ_ONLY=1`) refuses every mutating tool with a typed refusal. It is OFF by
default because the inventory's §13 Q5 is still a *recommendation* awaiting the owner's word, and a fleet
tool that silently refuses to dispatch is worse than one that declares what it does. What is NOT deferred is
the declaration: `readOnlyHint`/`destructiveHint` are explicit and tested on every tool.

INVARIANT 5 IS A START GATE, NOT A REPORT
-----------------------------------------
`instrument_versions()` lists each wrapped module's path and sha256, and **the server refuses to start when
one is missing** (exit 3, the refusal naming every missing module). The measured failure behind this: a
checkout **151 commits behind its pin**, so `scripts/` on that box — including the merge rail — was older
than the box claimed, while every instrument agreed with the stale copy. A version nobody can read is a
stale deployed copy that is DETECTABLE, not silent.

The external verbs (`cmux`, `gh`) are reported in `instrument_versions()` as `external` and are **not**
gated: they are the transport, not the implementation, and a cell legitimately has no `cmux`. Their absence
surfaces in the tool that needs them as `UNMEASURED(<verb> + not found)`.

TRANSPORT
---------
MCP stdio: newline-delimited JSON-RPC 2.0 on stdin/stdout, nothing else on stdout (logs go to stderr).
Zero third-party packages — a server that cannot start on a bare cell is an outage wearing a tool's name.

    initialize · notifications/initialized · tools/list · tools/call · ping
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from typing import Any, Dict, List, Optional, Tuple

SERVER_NAME = "orchestrator"
SERVER_VERSION = "0.2.0"
PROTOCOL_VERSION = "2024-11-05"

# ── what this server wraps ────────────────────────────────────────────────────────────────────
# ONE table, and it is the source of truth for three things at once: path resolution, the
# `instrument_versions()` payload, and the start gate. Adding a tool without adding its module here
# is therefore impossible without the invariant-5 test going red.
#
#             key                  env seam                    repo-relative path                       runner
WRAPPED: Tuple[Tuple[str, str, str, str], ...] = (
    ("lane_registry", "LANE_REGISTRY_PY", "scripts/orchestrator-harness/lane_registry.py", "python"),
    ("lane_status", "ORCH_MCP_LANE_STATUS", "scripts/lane-status.py", "python"),
    ("lane_wip", "ORCH_MCP_LANE_WIP", "scripts/lane-wip.py", "python"),
    ("lane_artifacts", "ORCH_MCP_LANE_ARTIFACTS",
     "scripts/orchestrator-harness/lane-artifacts.sh", "bash"),
    ("beta_progress", "ORCH_MCP_BETA_PROGRESS", "scripts/beta-progress.py", "python"),
    ("capacity", "ORCH_MCP_CAPACITY", "scripts/orchestrator-harness/capacity.sh", "bash"),
    ("box_status", "ORCH_MCP_BOX_STATUS", "scripts/orchestrator-harness/box-status.sh", "bash"),
    ("pr_state", "ORCH_MCP_PR_STATE", "tools/fleet/pr_state.py", "python"),
    ("claim_lanes", "ORCH_MCP_CLAIM_LANES", "tools/fleet/claim_lanes.py", "python"),
    ("liveness", "ORCH_MCP_LIVENESS", "tools/fleet/liveness.py", "python"),
    ("nonblocking_dispatch", "ORCH_MCP_DISPATCH",
     "scripts/orchestrator-harness/nonblocking-dispatch.sh", "bash"),
    ("record_review", "ORCH_MCP_RECORD_REVIEW", "scripts/record-review.sh", "bash"),
    ("merge_reminder", "ORCH_MCP_MERGE_REMINDER",
     "scripts/orchestrator-harness/merge-reminder.py", "python"),
    ("cycle_record", "ORCH_MCP_CYCLE_RECORD", "scripts/orchestrator-harness/cycle-record.sh", "bash"),
    ("report", "ORCH_MCP_REPORT", "scripts/orchestrator-harness/report.sh", "bash"),
)

# External CLI verbs. Reported, never gated (see the module docstring).
EXTERNAL: Tuple[Tuple[str, str], ...] = (("cmux", "cmux"), ("gh", "gh"))

# ── the surface, with ALL FOUR annotations on every tool ─────────────────────────────────────
# ⛔ `openWorldHint` IS TRUE ON THE READ ROWS TOO, AND `False` WAS A MISDECLARATION. The spec's
# definition is "may interact with an OPEN WORLD of external entities", NOT "may write": every one of
# the eight read tools reaches OUTSIDE this process — `lane.list`/`lane.show`/`lane.artifact` read the
# registry's git REMOTE and the cells, `fleet.census`/`pr.queue`/`pr.closure_audit` run `gh` against
# GitHub, `claim.check` reads a remote ref namespace, `pr.review_record` fetches the PR diff. A client
# reads `readOnlyHint: true` + `openWorldHint: false` as the "safe, closed, local" quadrant it may
# auto-approve, so declaring `False` here was wrong in the PERMISSIVE direction — the exact error the
# box.exec row's own comment warns about, in the other half of the table.
_READ = {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True,
         "openWorldHint": True}

TOOLS: List[Dict[str, Any]] = [
    {
        "name": "lane.list",
        "description": (
            "Every lane the fleet has a STATE RECORD for, with the four-state reading "
            "RUNNING | DONE | FAILED | EXPIRED. Answers, from the records alone: which lanes are "
            "running; which finished and with what artifacts/shas; which failed and why; which "
            "expired (no heartbeat past the stated budget, no terminal record); and the oldest "
            "unfinished lane. `EXPIRED` is DERIVED from the record's lease — never written. "
            "`liveness: true` adds the LANE-STATE-DECISION-TREE reading per lane (steps 1-4 as "
            "`tools/fleet/liveness.py::evaluate`, step 6 as the same function applied to the child); "
            "`tree: true` includes the child nodes. An unreadable registry returns UNMEASURED(<cmd> "
            "+ <error>), NEVER an empty list: unknown is not zero. Read-only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "state": {"type": "string", "enum": ["RUNNING", "DONE", "FAILED", "EXPIRED"],
                          "description": "only lanes in this state"},
                "host": {"type": "string", "description": "only lanes recorded on this host"},
                "repo": {"type": "string", "description": "only lanes for this owner/name"},
                "liveness": {"type": "boolean",
                             "description": "add the decision-tree reading (one fleet sample; "
                                            "costs one `lane-status.py --json --sample 2`)"},
                "tree": {"type": "boolean",
                         "description": "also verdict each lane's `task` child with the SAME function"},
            },
            "additionalProperties": False,
        },
        "annotations": dict(_READ),
    },
    {
        "name": "lane.show",
        "description": (
            "One lane's state record: state, state_reason (which cites the numbers the state was "
            "derived from), host/pid, branch/worktree, started_at/heartbeat_at/lease_until/budget_s, "
            "and the artifacts a DONE record is required to name. `liveness: true` adds the "
            "decision-tree reading — `alive` | `working` | `frozen` | `finished` | `no-verdict`, plus "
            "`dead: true` (and `state: \"dead\"`) ONLY on positive death evidence. Returns NOT-FOUND — "
            "exit-style — for an id with no record, which is a lookup outcome and NOT one of the "
            "states. Read-only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "lane_id": {"type": "string", "description": "the lane id"},
                "liveness": {"type": "boolean", "description": "add the decision-tree reading"},
                "tree": {"type": "boolean", "description": "also verdict this lane's `task` child"},
                "content": {"type": "boolean",
                            "description": "also attach the WIP words axis (`lane-wip.py --json`): "
                                           "step 5's INPUT, never its classification"},
            },
            "required": ["lane_id"],
            "additionalProperties": False,
        },
        "annotations": dict(_READ),
    },
    {
        "name": "lane.artifact",
        "description": (
            "WHAT is this lane's work in progress — the LAST ASSISTANT TURN, not the verdict (a verdict "
            "cannot tell 'finished' from 'stopped with work left'). Words axis: `lane-wip.py --json`. "
            "Files axis (optional): `lane-artifacts.sh` over the cells — `pattern` or `name` selects it, "
            "and 'none written' is a VALUE, not an error. Also reads the board's `LANE-DONE` line for "
            "this lane when one exists. Read-only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "lane": {"type": "string", "description": "lane label or workspace id"},
                "turns": {"type": "integer", "description": "how many last assistant turns (default 1)"},
                "chars": {"type": "integer", "description": "per-turn character cap (default 400)"},
                "pattern": {"type": "string", "description": "files axis: a /tmp glob fragment"},
                "name": {"type": "string", "description": "files axis: a lane's log name"},
                "box": {"type": "string", "description": "files axis: one cell label"},
            },
            "required": ["lane"],
            "additionalProperties": False,
        },
        "annotations": dict(_READ),
    },
    {
        "name": "fleet.census",
        "description": (
            "A repo-parameterised census, one typed object per repo plus this box's capacity: P0/P1 "
            "open·with-PR·NONE (`beta-progress.py --repo --json`), the placement gate and the fleet-wide "
            "capacity channel (`capacity.sh`), and this box's harness identity (`box-status.sh`). EVERY "
            "figure carries `measured_at`, `age_m` and `source`, and `platform` names which of the TWO "
            "capacity calibrations applies (macOS laptop vs Linux cell — one threshold across both "
            "fails in the reassuring direction). Read-only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repos": {"type": "array", "items": {"type": "string"},
                          "description": "owner/name list (default: daniel-ospina/tortoise)"},
                "capacity": {"type": "boolean", "description": "include capacity.sh (default true)"},
                "box": {"type": "boolean", "description": "include box-status.sh (default true)"},
            },
            "additionalProperties": False,
        },
        "annotations": dict(_READ),
    },
    {
        "name": "pr.queue",
        "description": (
            "The PR queue for one repo: `pr_state.py`'s 15 actions (CLOSE-STALE, WAIT:*, REPAIR-CONFLICT, "
            "FIX-RED, RERUN-FLAKE, REVIEW, LAND …), its head-bound attestation fidelity, and the 6 "
            "classes the issue names as a VIEW over them (`class`), never as a replacement. An unreadable "
            "board is UNMEASURED, never an empty queue. Read-only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "description": "owner/name (default PR_STATE_REPO)"},
                "limit": {"type": "integer", "description": "how many open PRs to read (default 100)"},
                "pr": {"type": "integer", "description": "answer for ONE pr"},
                "closing": {"type": "boolean",
                            "description": "attach what this PR's merge actually closed (needs pr)"},
            },
            "additionalProperties": False,
        },
        "annotations": dict(_READ),
    },
    {
        "name": "claim.check",
        "description": (
            "The ref-claim registry for an issue, a PR or a head sha. ⛔ EVERY VERDICT IS AN ABSTENTION: "
            "a claim asserts a declared OWNERSHIP window, never that a process is alive — and an absent "
            "key is HEAD-scoped and transient, so it is NEVER freedom. `readable: false` means the "
            "namespace could not be consulted at all, which must never be read as 'no claims'. Read-only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "issue": {"type": "integer", "description": "the issue number"},
                "pr": {"type": "integer", "description": "the PR number"},
                "sha": {"type": "string", "description": "the head sha (12 chars used as the key)"},
                "repo": {"type": "string", "description": "a git checkout whose origin is read"},
            },
            "additionalProperties": False,
        },
        "annotations": dict(_READ),
    },
    {
        "name": "lane.dispatch",
        "description": (
            "Launch ONE lane through the harness's own launcher (`nonblocking-dispatch.sh`, which "
            "backgrounds `spawn-gate.sh::run_agent` — the load gate, the watchdog and the walltime row "
            "are the launcher's, never re-implemented here). REFUSALS ARE TYPED and are a MAPPING onto "
            "the existing vocabulary: 80 brief refused, 73 fork, 77 disk, 75 load, 74 land backlog, 78 "
            "cannot-verify, 72 repo target — plus the two that had no code (`no-pid`, `branch-exists`). "
            "Reads the pid from the `.pid` file, never from the launcher's stdout. MUTATING."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "the lane name"},
                "worktree": {"type": "string", "description": "the lane's worktree directory"},
                "brief": {"type": "string", "description": "path to the brief file"},
                "backstop_s": {"type": "integer", "description": "absolute wall-clock backstop"},
                "kind": {"type": "string", "description": "what is being spawned (default bg)"},
                "branch": {"type": "string",
                           "description": "if given, refuse BEFORE launching when it already exists"},
                "env": {"type": "object", "additionalProperties": {"type": "string"},
                        "description": "environment for the agent process"},
            },
            "required": ["name", "worktree", "brief"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": False,
                        "openWorldHint": True},
    },
    {
        "name": "box.exec",
        "description": (
            "Run ONE allowlisted command on one box over `cmux vm exec`, and return "
            "{rc, stdout, stderr, timed_out, truncated}. ⛔ `argv` IS AN ARRAY — there is no shell "
            "string anywhere in this path, because an allowlist over `sh -c` is defeated by `sh` itself. "
            "A command that is not on the allowlist is a TYPED REFUSAL (`command-not-allowlisted`), never "
            "a pass-through. ⛔ `timed_out` / `truncated` are CHANNEL facts: they are never evidence about "
            "the box, and a timeout is never reported as `box-unreachable` (a disk-full guest answers "
            "`running` while every exec times out). MUTATING."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "box": {"type": "string", "description": "cell label or vm name"},
                "argv": {"type": "array", "items": {"type": "string"},
                         "description": "the command AND its arguments, as separate strings"},
                "timeout_s": {"type": "integer", "description": "channel timeout (default 60)"},
                "max_output": {"type": "integer", "description": "stdout cap in bytes (default 20000)"},
            },
            "required": ["box", "argv"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": True, "idempotentHint": False,
                        "openWorldHint": True},
    },
    {
        "name": "pr.review_record",
        "description": (
            "Where a PR's review record stands: `current` | `stale` | `absent`, plus the head the record "
            "is bound to, from `record-review.sh --check-carry` (the gate's OWN predicate, passed "
            "POSITIONALLY). The seven verdicts keep their own names — `carry-patch` is RE-RECORD (not a "
            "review cycle) and `nodigest`/`unreadable` are RETRY (not re-review) — so three different next "
            "actions are never flattened into one. ⛔ This is step 1 of the five-step landing contract; it "
            "is NEVER a substitute for the fresh review. Read-only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "pr": {"type": "integer", "description": "the PR number"},
                "repo": {"type": "string", "description": "owner/name (positional to the script)"},
                "diff_hash": {"type": "boolean", "description": "also return the live diff hash"},
            },
            "required": ["pr"],
            "additionalProperties": False,
        },
        "annotations": dict(_READ),
    },
    {
        "name": "pr.closure_audit",
        "description": (
            "What a merge ACTUALLY closed: `gh pr view --json closingIssuesReferences` compared against "
            "the issue's OWN live `state`, emitting the closed / mentioned-but-open / still-open triple. "
            "⛔ A `#N` MENTION in a title, body or branch is NOT a closure — that is exactly the FALSE "
            "MERGED defect (7 PRs printed as merged, all seven `open`) this tool exists to replace. ⛔ And "
            "ancestry is not evidence: the rail squash-merges, so a batch's constituents stay OPEN. "
            "Read-only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "pr": {"type": "integer", "description": "the merged (or open) PR number"},
                "repo": {"type": "string", "description": "owner/name"},
            },
            "required": ["pr", "repo"],
            "additionalProperties": False,
        },
        "annotations": dict(_READ),
    },
    {
        "name": "fleet.reminder",
        "description": (
            "A settable, listable, cancellable reminder that SURVIVES a session restart: a file-backed "
            "queue under the state dir (a queue in server memory dies with the server, and surviving a "
            "restart is the requirement) plus the timer lifecycle `merge-reminder.py` already owns "
            "(`--install-timer` / `--uninstall-timer` / `--interval`; launchd on macOS, a systemd user "
            "timer on Linux). Delivery is confirmed by the TURN BOUNDARY, never by a send's exit status. "
            "MUTATING for `set`/`cancel`; `list` writes nothing."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["set", "list", "cancel"]},
                "id": {"type": "string", "description": "the reminder id (cancel)"},
                "message": {"type": "string", "description": "the reminder text (set)"},
                "due_at": {"type": "integer", "description": "epoch seconds (set)"},
                "every_s": {"type": "integer", "description": "recurring interval seconds, optional"},
                "install_timer": {"type": "boolean",
                                  "description": "also install/refresh the timer (set), or remove it "
                                                 "(cancel)"},
            },
            "required": ["action"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": False,
                        "openWorldHint": False},
    },
    {
        "name": "fleet.beat_checkpoint",
        "description": (
            "The durable cycle record. `read` is the LOOP-SAFE read path (`report.sh`, which reads only "
            "durable artifacts) plus `cycle-record.sh`'s own verdict — HEALTHY / DEGRADED / "
            "FORK-STARVED / ABSENT / UNREADABLE, where an absent or stale record is never healthy. "
            "`write` appends one cycle record through `cycle_record_write`. ⛔ It records ARTIFACTS and "
            "their verdict, never a claim, and it does not add a third checkpoint reader. Read-only for "
            "`read`; MUTATING for `write`."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["read", "write"]},
                "hours": {"type": "integer", "description": "read: window in hours (default 12)"},
                "o": {"type": "string", "description": "the orchestrator state dir ($O)"},
                "state": {"type": "object", "additionalProperties": {"type": "string"},
                          "description": "write: cycle_record_write's key=value fields"},
            },
            "required": ["action"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": False,
                        "openWorldHint": False},
    },
]

TOOL_NAMES = tuple(t["name"] for t in TOOLS)

# The surface the owner approved for Phase 2: 10 new names + the extended pair (§5.9).
APPROVED_SURFACE = (
    "lane.list", "lane.show", "lane.artifact", "fleet.census", "pr.queue", "claim.check",
    "lane.dispatch", "box.exec", "pr.review_record", "pr.closure_audit", "fleet.reminder",
    "fleet.beat_checkpoint",
)

# Exit codes the WATCHDOG/inventory already use, mapped to typed refusal names. Never re-derived.
DISPATCH_REFUSALS = {
    2: "usage", 72: "repo-target-refused", 73: "fork-refused", 74: "land-backlog",
    75: "load-ceiling", 76: "capacity-refused", 77: "disk-headroom", 78: "cannot-verify",
    80: "brief-refused",
}

# The 6 classes the issue names are a VIEW over pr_state's 15 actions (inventory §13 Q4).
PR_CLASS_VIEW = {
    "CLOSE-STALE": "STALE-ATTESTATION",
    "REPAIR-CONFLICT": "CONFLICT",
    "FIX-RED": "READY",
    "RERUN-FLAKE": "READY",
    "REVIEW": "NO-ATTESTATION",
    "LAND": "READY",
}
for _action in ("WAIT:draft",):
    PR_CLASS_VIEW[_action] = "DRAFT"
for _action in ("WAIT:inherited-red",):
    PR_CLASS_VIEW[_action] = "INHERITED-RED"
for _action in ("WAIT:attested-elsewhere", "WAIT:owes-review", "WAIT:diff-unreadable"):
    PR_CLASS_VIEW[_action] = "STALE-ATTESTATION"
for _action in ("WAIT:in-flight", "WAIT:no-check-surface", "WAIT:mergeable-unknown",
                "WAIT:authority-unreadable"):
    PR_CLASS_VIEW[_action] = "WAIT"

# `record-review.sh --check-carry`'s verdicts (scripts/record-review.sh:40-67, `:2243+`). Each keeps its
# own name because each has its own NEXT ACTION — flattening them is how a re-record becomes a re-review.
CARRY_VERDICTS = {
    "head": ("current", "record matches the live head — step 2 (ONE fresh review) may proceed"),
    "carry": ("stale", "the record carries to this head — re-record, no review cycle"),
    "carry-patch": ("stale", "byte-identical patch on a moved diff — RE-RECORD, not a review cycle"),
    "fresh": ("absent", "no usable record for this head — ONE fresh review is required"),
    "norecord": ("absent", "no record on this box — registry-sync may hold one minted elsewhere"),
    "nodigest": ("absent", "a record exists with no usable digest — treat as absent, RETRY the digest"),
    "unreadable": ("absent", "the record exists but could not be read — RETRY, not a re-review"),
}


# ── path resolution + the start gate (invariant 5) ───────────────────────────────────────────

def _repo_root() -> str:
    return os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def _candidate_paths(env_name: str, relpath: str) -> List[str]:
    here = os.path.dirname(os.path.abspath(__file__))
    home = os.environ.get("CELL_HOME") or os.environ.get("HOME") or os.path.expanduser("~")
    base = os.path.basename(relpath)
    out = [
        os.environ.get(env_name, ""),
        # ⛔ THIS CHECKOUT FIRST, AND THEN `AGENT_INFRA_PATH`. The reverse order was a real defect found
        # by this suite's own fixtures: `AGENT_INFRA_PATH` in the environment pointed at the MAIN
        # checkout, so a server running from a worktree loaded the main checkout's copies of its own
        # modules — every one of them, silently. That is the F10 stale-deployed-copy failure with a
        # different filename, and the checkout this process LIVES IN is the most specific identity it
        # has. A deliberate override still wins, because the explicit env seam comes first.
        os.path.abspath(os.path.join(here, "..", "..", relpath)),
        os.path.join(os.environ.get("AGENT_INFRA_PATH", ""), relpath),
        os.path.join(os.environ.get("O", os.path.join(home, "orchestrator")), base),
        os.path.join(home, ".pi", "agent", "scripts", base),
        os.path.join(home, ".pi", "agent", "scripts", "fleet", base),
    ]
    return [p for p in out if p]


def _sha256(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


class Modules:
    """Every wrapped module, resolved once and FINGERPRINTED — plus the start gate.

    ⛔ THE FINGERPRINT IS PART OF THE ANSWER, NOT DEBUG OUTPUT (#3016): a checkout 151 commits behind its
    pin ran a `scripts/` tree older than the box claimed, and every instrument on that box agreed with the
    stale copy. So each module's sha256 is reported, and a MISSING module is a refusal to start rather than
    a degraded answer — the `no-op gate` polarity invariant 5 exists to forbid.
    """

    def __init__(self) -> None:
        self.paths: Dict[str, Optional[str]] = {}
        self.sha: Dict[str, Optional[str]] = {}
        self.missing: List[str] = []
        self.errors: Dict[str, str] = {}
        self._digest: Optional[str] = None
        for key, env_name, relpath, _runner in WRAPPED:
            found = None
            for candidate in _candidate_paths(env_name, relpath):
                if candidate and os.path.isfile(candidate):
                    found = candidate
                    break
            self.paths[key] = found
            if found is None:
                self.missing.append(key)
                self.errors[key] = "not found in: %s" % ", ".join(_candidate_paths(env_name, relpath))
                self.sha[key] = None
                continue
            try:
                self.sha[key] = _sha256(found)
            except OSError as exc:
                self.missing.append(key)
                self.errors[key] = "%s: %s" % (found, exc)
                self.sha[key] = None

    def path(self, key: str) -> Optional[str]:
        return self.paths.get(key)

    def digest(self) -> str:
        """One join key over the module→sha256 map, computed ONCE per resolution.

        ⛔ It exists so a tool payload can be tied to the exact module set that answered it without
        repeating sixteen rows in every result. The full map is on
        `initialize.serverInfo.instrument_versions`, which is what this digest is taken over.
        """
        if self._digest is None:
            blob = json.dumps([(row["module"], row["sha256"])
                               for row in instrument_versions(self)["modules"]], sort_keys=True)
            self._digest = hashlib.sha256(blob.encode()).hexdigest()
        return self._digest

    def runner(self, key: str) -> str:
        for k, _env, _rel, runner in WRAPPED:
            if k == key:
                return runner
        raise KeyError(key)


def instrument_versions(mods: Optional[Modules] = None) -> Dict[str, Any]:
    """Invariant 5's payload: one row per wrapped module, with its sha256.

    `ok` is False when ANY module is missing — and `serve()` refuses to start on a False, so this is the
    gate's own reading rather than a second opinion about it.
    """
    mods = mods or Modules()
    rows = []
    for key, _env, relpath, runner in WRAPPED:
        rows.append({
            "module": key,
            "path": mods.paths.get(key),
            "sha256": mods.sha.get(key),
            "runner": runner,
            "wraps": relpath,
            "present": mods.paths.get(key) is not None,
            "error": mods.errors.get(key),
        })
    external = []
    for name, binary in EXTERNAL:
        where = _which(binary)
        external.append({"verb": name, "path": where, "present": where is not None})
    return {
        "measured_at": _now(),
        "modules": rows,
        "external": external,
        "ok": not mods.missing,
        "missing": list(mods.missing),
        # ⛔ DECLARED, NOT GATED, and the reason is measured: this hashes WHAT THIS PROCESS LOADED. The
        # `harness-provenance.sh check` half of §11 answers a DIFFERENT question — "is the deployed tree
        # the committed one" — and its record does not reach every directory the fleet runs from ($HOME/
        # .pi/agent/scripts, tools/fleet), which §11 names as the real gap. Gating startup on it would
        # refuse a healthy box for a gap in the record, so it is reported as `unknown` instead of being
        # read as a pass.
        "deployed_drift": "unknown(harness-provenance.sh check not consulted: its record does not cover "
                          "every deployed directory — inventory §11)",
    }


def _gh() -> str:
    """The `gh` in use. An env seam, because a test that reaches the live API is not a test."""
    return os.environ.get("ORCH_MCP_GH") or _which("gh") or "gh"


def _cmux() -> Optional[str]:
    """The `cmux` in use. `None` when absent, which is a NAMED abstention — never an empty result."""
    return os.environ.get("ORCH_MCP_CMUX") or _which("cmux")


def _which(binary: str) -> Optional[str]:
    for d in (os.environ.get("PATH") or "").split(os.pathsep):
        if not d:
            continue
        candidate = os.path.join(d, binary)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


class StartRefused(RuntimeError):
    """Invariant 5: a wrapped module is missing, so there is no honest answer to serve."""

    def __init__(self, versions: Dict[str, Any]) -> None:
        self.versions = versions
        RuntimeError.__init__(self, "refusing to start: %d wrapped module(s) missing: %s"
                              % (len(versions["missing"]), ", ".join(versions["missing"])))


# ── the subprocess boundary: one runner, so every failure has ONE shape ──────────────────────

class Ran:
    """One finished (or not) command. ⛔ THE SHAPE IS THE CONTRACT — every tool reports failures through
    it, so `UNMEASURED(<cmd> + <error>)` can never drift between tools."""

    __slots__ = ("argv", "rc", "stdout", "stderr", "timed_out", "truncated", "error", "cap", "seconds")

    def __init__(self, argv, rc=None, stdout="", stderr="", timed_out=False, truncated=False,
                 error="", cap=0, seconds=0.0):
        self.argv = list(argv)
        self.rc = rc
        self.stdout = stdout
        self.stderr = stderr
        self.timed_out = timed_out
        self.truncated = truncated
        self.error = error
        self.cap = cap
        self.seconds = seconds

    @property
    def cmd(self) -> str:
        # The COMMAND, not the whole line: a payload is not a log, and an argv can carry a message.
        return " ".join(shlex.quote(a) for a in self.argv[:4])

    def ok(self) -> bool:
        return self.rc == 0 and not self.timed_out and not self.error

    def reason(self) -> str:
        """THE reason, and it must be the READ'S own cause (invariant 1)."""
        if self.error:
            return self.error
        if self.timed_out:
            return "timeout after %.1fs" % self.seconds
        first = ""
        for line in (self.stderr or "").splitlines():
            if line.strip():
                first = line.strip()
                break
        return "rc=%s%s" % (self.rc, (": " + first[:300]) if first else "")

    def unmeasured(self) -> str:
        return "UNMEASURED(%s + %s)" % (self.cmd, self.reason())

    def to_dict(self) -> Dict[str, Any]:
        return {"argv": self.argv, "rc": self.rc, "stdout": self.stdout, "stderr": self.stderr,
                "timed_out": self.timed_out, "truncated": self.truncated,
                "truncated_at_bytes": self.cap if self.truncated else None,
                "error": self.error, "seconds": round(self.seconds, 3)}


def _decode(raw: bytes, cap: int) -> Tuple[str, bool]:
    text = raw.decode("utf-8", "replace")
    return (text[:cap], True) if len(raw) > cap else (text, False)


# ⛔ `cap` BOUNDS WHAT IS RETURNED, NOT WHAT IS BUFFERED — AND THAT WAS AN OUTAGE. `run()` used
# `subprocess.run(stdout=PIPE)`, which reads the WHOLE stream into memory and truncates afterwards, so
# `box.exec {"argv": ["cat", "/dev/zero"]}` buffered without limit until the OOM killer took the MCP
# server — i.e. the entire tool surface for that session — from a READ-ONLY, allowlisted command.
# Measured with this module's own `run()`: one 128 MB stream took peak RSS from 71.6 MB to 282.9 MB
# while returning 100 bytes. `timeout_s` was also unbounded (`int(args.get("timeout_s") or 60)`, no
# maximum in the schema), so `timeout_s: 86400` made it unbounded in TIME as well. The realistic
# trigger is not hostile: `cat` of a large log is the diagnostic use this tool exists for.
# ⛔ THE MAXIMA MUST COVER THE LARGEST DECLARED CALL SITE, OR THE CLAMP SILENTLY REWRITES IT. `pr_state`
# asks for `timeout=400.0` (the whole-board `gh` read); a `MAX_TIMEOUT_S` of 300 turned a slow-but-
# legitimate read into a FALSE `UNMEASURED(... timeout after 300s)` — the exact failure class (#3382
# invariant 1: unknown is not zero) this PR exists to remove, introduced by its own bound. A guard arm
# parses this file and reds if any call site declares more than the constant.
MAX_TIMEOUT_S = 420          # > the largest declared call site (400.0, `pr_state`)
# ⛔ THE CHANNEL'S MARGIN HAS TO FIT *INSIDE* THE BOUND, NOT SIT ABOVE IT. `box.exec` asks the channel
# for `timeout_s + CHANNEL_MARGIN_S` ON PURPOSE — the transport's own `--timeout` must answer before the
# local kill, or the answer is discarded as `CHANNEL-TIMEOUT`. The clamp used the SAME `MAX_TIMEOUT_S`
# on both halves of that expression, so for any `timeout_s > MAX_TIMEOUT_S - CHANNEL_MARGIN_S` the
# margin was clamped straight back off: the local kill fired at the instant the transport would have
# answered, rc was None, and a slow-but-legitimate exec was reported as a channel timeout. That is the
# "clamp silently rewrites a declared call site" class inside the one site the literal-only guard arm
# could not see (`timeout=timeout_s + 30` is not a literal).
CHANNEL_MARGIN_S = 30        # the local kill fires this long AFTER the transport's own --timeout
MAX_CHANNEL_TIMEOUT_S = MAX_TIMEOUT_S + CHANNEL_MARGIN_S
MAX_CAP = 2_000_000          # a declared maximum for the returned-bytes cap
_DEFAULT_TIMEOUT_S = 60.0    # what a degenerate/absent request falls back to
_DEFAULT_CAP = 200_000
_DRAIN_CHUNK = 65536


def _drain_into(sink: "bytearray", stream, cap: int, state: Dict[str, Any]) -> None:
    """Read up to `cap` bytes into `sink`, then DRAIN AND DISCARD so the child never blocks.

    ⛔ DISCARDING MATTERS MORE THAN THE CAP. If the reader stopped at `cap`, the child would block
    forever on a full pipe and the call would hang to its timeout (or, with `subprocess.run`, the
    WHOLE stream would be buffered). Draining keeps the memory at `cap` and the pipe moving, so an
    endless producer is bounded by the TIMEOUT rather than by the machine's RAM.
    """
    try:
        while True:
            chunk = stream.read(_DRAIN_CHUNK)
            if not chunk:
                return
            room = cap - len(sink)
            if room > 0:
                sink.extend(chunk[:room])
                if len(chunk) > room:
                    state["truncated"] = True
            else:
                state["truncated"] = True
    except (OSError, ValueError):
        return


def run(argv: List[str], timeout: float = 60.0, cap: int = 200_000,
        env: Optional[Dict[str, str]] = None) -> Ran:
    if not argv:
        return Ran(argv, error="empty argv")
    # ⛔ CLAMPED, NOT TRUSTED. `timeout` arrives from a tool argument on the `box.exec` path.
    # ⛔ AND A DEGENERATE VALUE FALLS BACK TO THE DEFAULT, NEVER TO THE MAXIMUM: `cap < 0` used to be
    # mapped to `MAX_CAP`, i.e. a nonsense-low request produced the LARGEST buffer — the wrong
    # direction for the very bound this fix exists to impose.
    try:
        timeout = float(timeout)
    except (TypeError, ValueError):
        timeout = _DEFAULT_TIMEOUT_S
    if not (timeout > 0):
        timeout = _DEFAULT_TIMEOUT_S
    elif timeout > MAX_CHANNEL_TIMEOUT_S:
        # The CHANNEL bound, not the caller bound: a call site may legitimately request the caller's
        # maximum PLUS its declared margin (see CHANNEL_MARGIN_S), and clamping that back to the caller
        # bound would silently discard the margin the caller asked for.
        timeout = MAX_CHANNEL_TIMEOUT_S
    try:
        cap = int(cap)
    except (TypeError, ValueError):
        cap = _DEFAULT_CAP
    if cap < 0:
        cap = _DEFAULT_CAP
    elif cap > MAX_CAP:
        cap = MAX_CAP
    started = time.time()
    environ = dict(os.environ)
    environ.update(env or {})
    try:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=environ)
    except (OSError, ValueError) as exc:
        return Ran(argv, error="%s: %s" % (type(exc).__name__, exc), cap=cap,
                   seconds=time.time() - started)
    # Two independent pipes, so two drainers: reading one to EOF while the other fills would deadlock
    # on a child that writes both.
    out_buf, err_buf = bytearray(), bytearray()
    state: Dict[str, Any] = {"truncated": False}
    drainers = [threading.Thread(target=_drain_into, args=(out_buf, proc.stdout, cap, state),
                                 daemon=True),
                threading.Thread(target=_drain_into, args=(err_buf, proc.stderr, cap, state),
                                 daemon=True)]
    for t in drainers:
        t.start()
    timed_out = False
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            proc.kill()
        except OSError:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
    for t in drainers:
        t.join(timeout=10)
    out, trunc = _decode(bytes(out_buf), cap)
    err, etrunc = _decode(bytes(err_buf), cap)
    if timed_out:
        return Ran(argv, rc=None, stdout=out, stderr=err, timed_out=True,
                   truncated=trunc or etrunc or state["truncated"],
                   cap=cap, seconds=time.time() - started)
    return Ran(argv, rc=proc.returncode, stdout=out, stderr=err,
               truncated=trunc or etrunc or state["truncated"],
               cap=cap, seconds=time.time() - started)


def run_module(mods: Modules, key: str, args: List[str], timeout: float = 60.0,
               cap: int = 200_000) -> Ran:
    """Run a wrapped module through its OWN runner (python3 / bash) and its OWN path."""
    path = mods.path(key)
    if not path:
        return Ran(str(path), error="module %r not resolved: %s"
                   % (key, mods.errors.get(key, "unknown")))
    head = [path] if os.access(path, os.X_OK) else (
        ["bash", path] if mods.runner(key) == "bash" else [sys.executable, path])
    return run(head + args, timeout=timeout, cap=cap)


def _now() -> int:
    return int(time.time())


def _iso(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def _age(epoch: float) -> str:
    """Computed age of a measurement, in the shape the rest of the fleet prints it.

    Invariant 4: a number travels with its measurement time AND a computed age. A bare epoch is a
    number nobody can reason about without doing arithmetic, and arithmetic done twice is how two
    lanes end up disagreeing about how old the same snapshot is.
    """
    delta = max(0, int(_now() - epoch))
    if delta < 60:
        return "%ds" % delta
    if delta < 3600:
        return "%dm" % (delta // 60)
    if delta < 86400:
        return "%dh%02dm" % (delta // 3600, (delta % 3600) // 60)
    return "%dd%02dh" % (delta // 86400, (delta % 86400) // 3600)


def parse_payload(ran: Ran, what: str) -> Tuple[Optional[Any], Optional[str]]:
    """Parse stdout as JSON **regardless of exit status**.

    ⛔ SOME CONTRACTS CARRY THE ABSTENTION IN THE PAYLOAD WITH A NON-ZERO CODE: `lane-wip.py` exits 3 with
    `{"unmeasured": ...}` and `claim_lanes.py` exits 3 with the whole claim read. Parsing only on `rc == 0`
    throws those payloads away and then reports the wrong cause — the FALSE UNMEASURED defect with the
    sign flipped.
    """
    if ran.error or ran.timed_out:
        return None, ran.unmeasured()
    try:
        return json.loads(ran.stdout), None
    except (ValueError, TypeError):
        if not ran.ok():
            return None, ran.unmeasured()
        return None, ("UNMEASURED(%s -> rc=0 + payload for %s is not JSON: the command RAN and its "
                      "output could not be read, which is NOT the same as the command failing)"
                      % (ran.cmd, what))


def parse_json(ran: Ran, what: str) -> Tuple[Optional[Any], Optional[str]]:
    if not ran.ok():
        return None, ran.unmeasured()
    try:
        return json.loads(ran.stdout), None
    except (ValueError, TypeError) as exc:
        return None, ("UNMEASURED(%s -> %s + payload for %s is not JSON (%s): the command RAN and its "
                      "output could not be read, which is NOT the same as the command failing)"
                      % (ran.cmd, ran.reason(), what, type(exc).__name__))


# ── the liveness axis: ONE verdict function, applied ─────────────────────────────────────────

# ⛔ MIRRORS `scripts/lane-status.py`'s `ABANDON_S` (= 30 * 60), THE PRODUCER'S OWN BOUND FOR
# "may this child record still SUPPRESS an action verdict". `lane-status.py` runs as a SUBPROCESS here
# (see `fleet_rows`), so the value cannot be imported — it is named once, here, with a parity arm in
# `test_server.py` that reads the producer's definition and reds if the two drift.
# ⛔ WHY IT IS NEEDED AT ALL: `child_stale` is an AGE IN SECONDS, not a flag (`lane-status.py`:
# `int(time.time() - os.path.getmtime(child_file))`). `bool()` collapses "any age >= 1 s" to "stale",
# which silently drops the step-3 veto for every child older than one second — i.e. exactly the
# `FINDING-lane-classifier-ignores-task-children` defect the step exists to fix.
CHILD_ABANDON_S = 30 * 60


class Liveness:
    """The decision tree, applied to a registry record.

    ⛔ `tools/fleet/liveness.py::evaluate` is the ONLY classifier (issue §1.2, §4.2). This class acquires
    EVIDENCE and calls it; it never decides a state. Each step's evidence either exists or is a NAMED
    abstention, and a `None` slot is inert in `evaluate` by construction.

    The mapping onto the issue's surface states happens HERE, because `finished` is a REGISTRY state
    (`DONE`/`FAILED`), not a `liveness.STATES` member — putting it in `evaluate` would make one function
    answer two vocabularies.
    """

    SURFACE = ("alive", "working", "frozen", "finished", "no-verdict")

    def __init__(self, mods: Modules) -> None:
        self.mods = mods
        self.module = self._load()

    def _load(self):
        path = self.mods.path("liveness")
        if not path:
            return None
        try:
            spec = importlib.util.spec_from_file_location("liveness_served", path)
            mod = importlib.util.module_from_spec(spec)
            sys.modules["liveness_served"] = mod
            spec.loader.exec_module(mod)
            return mod
        except Exception:                              # noqa: BLE001 - an abstention, never a crash
            return None

    def fleet_rows(self, timeout: float = 200.0) -> Tuple[Optional[List[Dict[str, Any]]], str]:
        """ONE fleet sample (`lane-status.py --json --sample 2`) — the beat's own call, not a second
        CPU reader (inventory D7). Returns (rows, note)."""
        ran = run_module(self.mods, "lane_status", ["--json", "--sample", "2"], timeout=timeout)
        rows, why = parse_json(ran, "the lane table")
        if rows is None:
            return None, why
        return (rows if isinstance(rows, list) else None), "lane-status.py --json --sample 2"

    def evidence(self, row: Dict[str, Any], lane_rows: Optional[List[Dict[str, Any]]],
                 note: str) -> Tuple[Any, Dict[str, Any]]:
        """Build Evidence for ONE registry record, and say where each input came from."""
        lv = self.module
        sources: Dict[str, Any] = {}
        if lv is None:
            sources["module"] = "UNMEASURED(resolve tools/fleet/liveness.py + not loadable)"
            return None, sources
        now_ms = _now() * 1000
        pid = row.get("pid")
        cands: List[Any] = []
        ps_ok = True
        if pid is None:
            ps_ok = False
            sources["process"] = "UNMEASURED(registry record names no pid)"
        else:
            # ⛔ `probe-argv`, NOT `probe <pid> ""`. The registry records a pid and no `pidStartSeconds`,
            # and the fence REFUSES an empty stamp BY DESIGN (`unknown reason=unusable-start-seconds`) —
            # so asking it for one makes every registry lane read `ps-unreadable`. What can honestly be
            # said about a pid with no start stamp is "a process with this pid is alive", which is
            # `probe-argv`'s own claim, and it comes from the SAME identity library — not a second one.
            probe = lv.probe_argv(int(pid))
            observed = lv.observed_from_probe(probe.rc, probe.status)
            if observed == "unreadable":
                ps_ok = False
            cands.append(lv.Candidate(pid=int(pid), observed=observed, kind="argv",
                                      start_seconds=None, detail="registry-record"))
            sources["process"] = {"pid": int(pid), "observed": observed, "probe_rc": probe.rc,
                                  "source": "pid-identity.sh probe-argv",
                                  "fence": "argv-presence only: the registry records no start seconds, so "
                                           "no incarnation fence exists for this candidate"}
        # step 4's PROXY, LABELLED. A registry record has no session id, so there is no transcript to
        # read; what the launcher DOES write is a heartbeat whose budget is its own. Growth is
        # therefore "the record advanced inside its lease" and non-growth is "the lease lapsed" —
        # exactly the pair `evaluate` needs, with `age_source` naming the substitution so no reader
        # mistakes it for a transcript read.
        beat = row.get("heartbeat_at")
        budget = row.get("budget_s") or 0
        try:
            age_ms = max(0, now_ms - int(beat) * 1000) if beat else None
        except (TypeError, ValueError):
            age_ms = None
        grew = None
        if age_ms is not None and budget:
            grew = age_ms <= int(budget) * 1000
        sources["step4"] = {"age_ms": age_ms, "grew": grew, "age_source": "registry-heartbeat",
                            "budget_s": budget}
        cpu = None
        child = None
        if lane_rows is not None:
            joined = self._join(row, lane_rows)
            if isinstance(joined, dict):
                # ⛔ THE ROW'S KEY IS `cpu`, NOT `cpu_busy` (verified against the producer:
                # `lane-status.py`'s `out.append(dict(..., cpu=_cpu, cpu_any=_cpu_any, ...))`).
                # `cpu_busy` exists ONLY as a `classify()` keyword there, so reading it here returned
                # `None` on every row — step 2 could never fire on this surface, while the payload
                # published `source="lane-status.py::lane_cpu_busy"` and a `step2` block naming a
                # measurement nobody took. `lane_cpu_busy()`'s exactly-one-attribution answer is
                # `cpu`; `cpu_any` is the deliberately WEAKER #1867 read ("a pi in this lane's own
                # pane advanced") and is REPORTED, never promoted to step-2 evidence — promoting it
                # would claim an exact attribution the producer did not make.
                cpu_reading = joined.get("cpu")
                if not isinstance(cpu_reading, bool):
                    cpu_reading = None       # not-read is `None`, never a guessed False
                sources["step2"] = {"row": joined.get("ws"), "cpu": cpu_reading,
                                    "cpu_any": joined.get("cpu_any"), "source": note}
                if cpu_reading is None:
                    sources["step2"] = dict(
                        sources["step2"],
                        unmeasured="UNMEASURED(the row carries no `cpu` attribution: "
                                   "lane_cpu_busy declined, so step 2 abstains)")
                cpu = lv.CpuSample(advanced=cpu_reading, delta_s=None, window_ms=None,
                                   source=("lane-status.py::lane_cpu_busy" if cpu_reading is not None
                                           else ""))
                kid = joined.get("child")
                # ⛔ `child_stale` IS AN AGE IN SECONDS. The producer's own suppression rule is
                # `child_stale > ABANDON_S` (`child_suppresses`), and `None` (no child file, or an
                # unreadable stat) is "absence never counts against a child" -> NOT stale.
                cs = joined.get("child_stale")
                if isinstance(cs, bool) or not isinstance(cs, (int, float)):
                    cs = None
                child = lv.ChildEvidence(sid=str(kid or ""), in_flight=bool(kid),
                                         stale=(cs is not None and cs > CHILD_ABANDON_S),
                                         grew=joined.get("child_grew"),
                                         # ⛔ NAMES THE ARM, NOT THE FUNCTION. `child_suppresses` is
                                         # `(declared or pane_kids or live_child) and verdict in
                                         # ACTION_VERDICTS`, and the row carries `declared` and
                                         # `pane_children` too — which this join does NOT read. No
                                         # divergence today (that function's own measured notes say
                                         # both are always empty, so `live_child` is the only live
                                         # arm), but the label must not claim the whole rule: the
                                         # moment `declared_children` works, this surface could say
                                         # `frozen` where the producer says `WAITING-CHILD`, and
                                         # nothing in the payload would show which arm was used.
                                         source="lane-status.py::child_suppresses(live_child arm)")
                sources["step3"] = {"child": kid, "child_stale_s": cs,
                                    "abandon_s": CHILD_ABANDON_S, "stale": child.stale,
                                    "grew": joined.get("child_grew"), "source": note}
            else:
                sources["step2"] = "UNMEASURED(%s + %s)" % (note, joined)
                sources["step3"] = sources["step2"]
        else:
            sources["step2"] = "UNMEASURED(lane-status sample + not requested)"
            sources["step3"] = sources["step2"]
        ev = lv.Evidence(sid="", ps_ok=ps_ok, store_ok=True, candidates=cands,
                         jsonl_grew=grew, jsonl_age_ms=age_ms, jsonl_turn=None, tool=None,
                         record=None, now_ms=now_ms, cpu=cpu, child=child)
        return ev, sources

    def _join(self, row: Dict[str, Any], lane_rows: List[Dict[str, Any]]) -> Any:
        """Registry record → lane-status row, by WORKTREE, and only when EXACTLY ONE row matches.

        The registry is keyed by `lane_id` and cmux by label/workspace, and nothing in either carries the
        other's key — so a join is a claim, and `exactly one` is the only shape that makes it a safe one.
        Several lanes sharing one checkout is a MEASURED state (FINDING-lanes-shared-one-checkout), so an
        ambiguous match abstains instead of picking the first row (`lane_cpu_busy`'s own guard).
        """
        wt = (row.get("worktree") or "").rstrip("/")
        if not wt:
            return "no-worktree"
        hits = [r for r in lane_rows
                if (str(r.get("cwd") or "").rstrip("/") == wt)
                or (str(r.get("ws") or "").upper() == str(row.get("tag") or "").upper()
                    and row.get("tag"))]
        if len(hits) == 1:
            return hits[0]
        return "no-unique-lane-status-row (%d matched)" % len(hits)

    def read(self, row: Dict[str, Any], lane_rows: Optional[List[Dict[str, Any]]],
             note: str, tree: bool = False) -> Dict[str, Any]:
        verdict = None
        ev, sources = self.evidence(row, lane_rows, note)
        if ev is not None:
            verdict = self.module.evaluate(ev)
        payload: Dict[str, Any] = {
            "measured_at": _now(),
            "evidence_source": sources,
            "verdict": verdict.to_dict() if verdict is not None else None,
        }
        state, dead, reason = self.surface(row, verdict)
        payload["state"] = state
        payload["dead"] = dead
        payload["reason"] = reason
        if state == "dead":
            payload["pending_owner_decision"] = (
                "agent-infra#3382 §13 Q1 — is `dead` a SIXTH surface state? Until the owner answers, the "
                "five states stay the vocabulary for every other lane and `dead: true` carries this one, "
                "so a positive death finding is never reported as `no-verdict` (which §4.3 forbids) and "
                "never as `finished` (which invariant 3 forbids)")
        if tree:
            payload["children"] = self.recursive(row, lane_rows, note)
        return payload

    def recursive(self, row: Dict[str, Any], lane_rows: Optional[List[Dict[str, Any]]],
                  note: str) -> Any:
        """TREE STEP 6: *"apply THIS SAME TREE to the CHILD"* — the same function, on the child's own
        session id, which is what `lane-status.py` attributes per lane. Never a second rule."""
        if lane_rows is None:
            return "UNMEASURED(lane-status sample + not requested, so the child edge is unknown)"
        joined = self._join(row, lane_rows)
        if not isinstance(joined, dict):
            return "UNMEASURED(child of %s + %s)" % (row.get("lane_id"), joined)
        kid = joined.get("child")
        if not kid:
            return {"child": None, "note": "no task child attributed to this lane"}
        if self.module is None:
            return "UNMEASURED(evaluate + liveness.py not loadable)"
        try:
            ev = self.module.gather(str(kid))
            verdict = self.module.evaluate(ev)
        except Exception as exc:                       # noqa: BLE001 - an abstention
            return "UNMEASURED(gather/evaluate child %s + %s: %s)" % (kid, type(exc).__name__, exc)
        return {"child": str(kid), "verdict": verdict.to_dict(), "state": verdict.state,
                "reason": verdict.reason, "via": "liveness.gather + liveness.evaluate (same function)"}

    def surface(self, row: Dict[str, Any], verdict) -> Tuple[str, bool, str]:
        """The registry state and the tree verdict, mapped onto ONE surface vocabulary."""
        rec_state = str(row.get("state") or "")
        if rec_state == "DONE":
            return "finished", False, "registry-terminal:DONE"
        if rec_state == "FAILED":
            return "finished", False, ("registry-terminal:FAILED (%s)"
                                       % (row.get("reason") or "no reason recorded"))
        if rec_state == "EXPIRED":
            return ("no-verdict", False,
                    "registry-EXPIRED: no terminal record and the lease lapsed (%s)"
                    % (row.get("state_reason") or "lease-lapsed"))
        if verdict is None:
            return "no-verdict", False, "UNMEASURED(liveness evidence + the module could not be loaded)"
        if verdict.state == "dead":
            # ⛔ INVARIANT 3: a lane with a terminal record is `finished` whatever the process table says,
            # and that branch is above this one. `dead` is reachable ONLY from `RUNNING`.
            return "dead", True, verdict.reason
        if verdict.state == "wedged":
            return "frozen", False, verdict.reason
        if verdict.state == "running-quiet":
            # `jsonl-grew` / `cpu-advanced` / `child-in-flight` are the tree's PROGRESS evidence; the
            # remaining running-quiet reasons (a fresh record, a quiet window) are "alive, not proven
            # working" — the distinction the surface names `alive` vs `working` and never collapses.
            # ⛔ `jsonl-grew(writer-unidentified)` is the SAME reason as `jsonl-grew`; matching the bare
            # token read a growing lane as merely `alive` — a one-character defect with a whole state on
            # the other side of it.
            working = verdict.reason.split("(")[0] in ("cpu-advanced", "child-in-flight", "jsonl-grew")
            return ("working" if working else "alive"), False, verdict.reason
        if verdict.state == "idle":
            return "alive", False, verdict.reason
        return "no-verdict", False, verdict.reason


# ── the registry (lane.list / lane.show) ─────────────────────────────────────────────────────

class Registry:
    """`lane_registry.py` + the liveness axis. The payload builder stays the MODULE's (`list_payload`) —
    one derivation, two surfaces (pinned by test_S11)."""

    def __init__(self, mods: Optional[Modules] = None) -> None:
        self.mods = mods or Modules()
        self.path: Optional[str] = self.mods.path("lane_registry")
        self.sha256: Optional[str] = self.mods.sha.get("lane_registry")
        self.module = None
        self.error: Optional[str] = self.mods.errors.get("lane_registry")
        self.liveness = Liveness(self.mods)
        if self.path:
            try:
                spec = importlib.util.spec_from_file_location("lane_registry_served", self.path)
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                self.module = mod
                self.error = None
            except Exception as exc:                # noqa: BLE001 - a bad copy is an abstention
                self.error = "%s: %s: %s" % (self.path, type(exc).__name__, exc)

    def unmeasured(self) -> str:
        return "UNMEASURED(resolve lane_registry.py + %s)" % (self.error or "unknown failure")

    # ── lane.list ──
    def list(self, args: Dict[str, Any]) -> Tuple[bool, Any]:
        if self.module is None:
            return True, {"error": self.unmeasured(), "registry_sha256": None}
        # ⛔ AN ILLEGAL FILTER IS REFUSED HERE TOO, because this surface has no argparse `choices` — so
        # `state:"BOGUS"` used to answer a DEFINITE `RUNNING=0` with `isError: false`, while the CLI
        # exited 2 for the same argument.
        want_state = args.get("state")
        if want_state and str(want_state).strip().upper() not in self.module.STATES:
            return True, {"error": "invalid argument: state %r is not one of %s"
                                   % (want_state, list(self.module.STATES)),
                          "registry_sha256": self.sha256}
        ok, detail, rows, code, applied, extra = self.module.collect(
            _ns(remote=None, state=want_state, host=args.get("host"), repo=args.get("repo"),
                timeout=20.0))
        if not ok:
            head = "invalid argument" if code == self.module.USAGE else "UNMEASURED"
            return True, {"error": "%s(%s)" % (head, detail),
                          "unmeasured": "UNMEASURED(%s)" % detail,
                          "registry_path": self.path, "registry_sha256": self.sha256}
        payload = self.module.list_payload(detail, rows, applied, extra)
        payload["registry_path"] = self.path
        payload["registry_sha256"] = self.sha256
        payload["instrument_sha256"] = instrument_sha(self.mods)
        self._attach(payload, rows, args)
        # ⛔ `local-only` IS AN ERROR ON THIS SURFACE even though records were read: the question is about
        # the FLEET, and a fallback to this box's own copies answers a narrower one.
        return payload.get("coverage") != "shared", payload

    def _attach(self, payload: Dict[str, Any], rows: List[Dict[str, Any]],
                args: Dict[str, Any]) -> None:
        want = bool(args.get("liveness"))
        payload["liveness_requested"] = want
        if not want:
            payload["liveness"] = ("UNMEASURED(liveness + not requested: every lane's reading costs one "
                                   "fleet sample — ask with liveness:true)")
            return
        lane_rows, note = self.liveness.fleet_rows()
        tree = bool(args.get("tree"))
        per: Dict[str, Any] = {}
        summary: Dict[str, int] = {}
        for row in rows:
            got = self.liveness.read(row, lane_rows, note, tree=tree)
            per[row["lane_id"]] = got
            summary[got["state"]] = summary.get(got["state"], 0) + 1
        payload["liveness"] = per
        payload["liveness_counts"] = summary
        payload["liveness_vocabulary"] = list(Liveness.SURFACE) + ["dead"]
        payload["liveness_source"] = note

    # ── lane.show ──
    def show(self, args: Dict[str, Any]) -> Tuple[bool, Any]:
        lane_id = (args or {}).get("lane_id")
        if not lane_id:
            return True, {"error": "lane.show requires lane_id"}
        if self.module is None:
            return True, {"error": self.unmeasured(), "registry_sha256": None}
        ok, detail, rows, code, _applied, extra = self.module.collect(
            _ns(remote=None, state=None, host=None, repo=None, timeout=20.0))
        if not ok:
            return True, {"error": "UNMEASURED(%s)" % detail,
                          "unmeasured": "UNMEASURED(%s)" % detail,
                          "registry_path": self.path, "registry_sha256": self.sha256}
        coverage = self.module.coverage(str(extra.get("source") or "none"))
        for row in rows:
            if row["lane_id"] == lane_id:
                got = dict(row)
                got["measured_at"] = _now()
                got["coverage"] = coverage
                got["source"] = detail
                got["registry_path"] = self.path
                got["registry_sha256"] = self.sha256
                got["instrument_sha256"] = instrument_sha(self.mods)
                got["filters"] = {"lane_id": lane_id}
                if args.get("liveness"):
                    lane_rows, note = self.liveness.fleet_rows()
                    got["liveness"] = self.liveness.read(row, lane_rows, note,
                                                         tree=bool(args.get("tree")))
                else:
                    got["liveness"] = ("UNMEASURED(liveness + not requested: one fleet sample — ask "
                                       "with liveness:true)")
                if args.get("content"):
                    got["content"] = _lane_artifact(self.mods, lane_id, {})
                # ⛔ A LOCAL-ONLY READ IS AN ERROR HERE TOO — two answers to "is this complete?" on one
                # surface is the defect test_S15 pins.
                return coverage != "shared", got
        # ⛔ NOT-FOUND FROM A PARTIAL READ IS NOT A VERDICT
        if coverage != "shared":
            return True, {"error": "UNMEASURED(%s) — NOT-FOUND cannot be asserted from a read that did "
                                   "not reach the shared registry" % detail,
                          "registry_sha256": self.sha256}
        return True, {"not_found": lane_id,
                      "note": "NOT-FOUND is a lookup outcome, not one of the four states",
                      "coverage": coverage,
                      "registry_sha256": self.sha256}


def instrument_sha(mods: Modules) -> str:
    """The digest of the module→sha256 map (`Modules.digest`, computed once)."""
    return mods.digest()


def _ns(remote, state, host, repo, timeout):
    """The argparse-shaped namespace `collect()` expects — one adapter, so the MCP surface reuses the
    CLI's own derivation rather than re-implementing the four-state rule."""
    import argparse
    return argparse.Namespace(remote=remote, timeout=timeout, quiet=True, json=True,
                              state=state, host=host, repo=repo)


# ── the ten remaining tools ──────────────────────────────────────────────────────────────────

def _lane_artifact(mods: Modules, lane: str, args: Dict[str, Any]) -> Dict[str, Any]:
    """Words axis (`lane-wip.py --json`, which is a WRITE this PR made) + files axis
    (`lane-artifacts.sh`) + the board's `LANE-DONE` line. Every absence is named."""
    payload: Dict[str, Any] = {"measured_at": _now(), "lane": lane}
    wip_args = ["%s" % lane, "--json"]
    if args.get("turns"):
        wip_args += ["--turns", str(int(args["turns"]))]
    if args.get("chars"):
        wip_args += ["--chars", str(int(args["chars"]))]
    ran = run_module(mods, "lane_wip", wip_args, timeout=260.0)
    words, why = parse_payload(ran, "the WIP words axis")
    if words is None:
        payload["words"] = {"unmeasured": why}
    else:
        payload["words"] = dict(words, exit_code=ran.rc)
        if ran.rc == 2:
            payload["words"]["outcome"] = "NO-LANE"
        elif ran.rc == 3:
            payload["words"]["outcome"] = "UNMEASURED"
        else:
            payload["words"]["outcome"] = "ANSWERED"
    if args.get("pattern") or args.get("name"):
        if args.get("pattern"):
            files_args = ["collect", str(args["pattern"])]
        else:
            files_args = ["logs", str(args["name"])]
        if args.get("box"):
            files_args += ["--box", str(args["box"])]
        fran = run_module(mods, "lane_artifacts", files_args, timeout=180.0)
        # ⛔ 3 = ABSENT-EVERYWHERE IS A VALUE, NOT AN ERROR (row 3's own rule); 4 = UNMEASURED (absence
        # NOT claimed) and 5 = PULL-FAILED are the two that must never read as "nothing written".
        files = {"exit_code": fran.rc, "argv": fran.argv, "stdout": fran.stdout,
                 "stderr": fran.stderr, "truncated": fran.truncated}
        if fran.rc == 0:
            files["outcome"] = "FOUND"
        elif fran.rc == 3:
            files["outcome"] = "ABSENT-EVERYWHERE"
        elif fran.rc == 4:
            files["outcome"] = "UNMEASURED"
            files["unmeasured"] = fran.unmeasured()
        elif fran.rc == 5:
            files["outcome"] = "PULL-FAILED"
            files["unmeasured"] = fran.unmeasured()
        else:
            files["outcome"] = "UNMEASURED"
            files["unmeasured"] = fran.unmeasured() if not fran.ok() else "UNMEASURED(unexpected exit)"
        payload["files"] = files
    else:
        payload["files"] = "UNMEASURED(files axis + not requested: pass `pattern` or `name`)"
    payload["terminal_verdict"] = _lane_done_line(lane)
    return payload


def _state_dir() -> str:
    return os.environ.get("ORCH_MCP_STATE_DIR") or os.path.join(
        os.environ.get("CELL_HOME") or os.environ.get("HOME") or os.path.expanduser("~"),
        ".pi", "agent", "state")


def _lane_done_line(lane: str) -> Any:
    """`## LANE-DONE <verdict> <ts>` from the newest board — the convention BEAT-CHECKLIST.md states.

    ⛔ "none written" IS A VALUE (row 3's own rule), not an error; an unreadable state dir is a NAMED
    abstention, because those are two different things and only one of them is a fact about the lane.
    """
    d = _state_dir()
    try:
        boards = sorted((n for n in os.listdir(d) if n.startswith("ORCHESTRATION-BOARD-")),
                        reverse=True)
    except OSError as exc:
        return "UNMEASURED(read board dir %s + %s)" % (d, exc)
    if not boards:
        return {"value": "none written", "source": "no ORCHESTRATION-BOARD-* under %s" % d}
    path = os.path.join(d, boards[0])
    try:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                if "LANE-DONE" in line and lane.upper() in line.upper():
                    return {"value": line.strip().lstrip("#").strip(), "source": path}
    except OSError as exc:
        return "UNMEASURED(read %s + %s)" % (path, exc)
    return {"value": "none written", "source": path}


PLATFORM_CALIBRATION = {
    # ⛔ TWO RULES THAT POINT IN OPPOSITE DIRECTIONS (inventory §10.1). One threshold across both fails in
    # the REASSURING direction: the cell tolerance applied to a dying laptop calls it healthy.
    "macos": {"platform": "macos", "load_per_cpu_ceiling": 1.2,
              "source": "AGENTS.md — 'Load, not context, is the concurrency ceiling' (macOS laptop)",
              "note": "the Mac IS the load; above ~1.2 LPC or ~12 concurrent workstreams sessions become "
                      "unreachable, and the remedy is fewer workstreams"},
    "linux": {"platform": "linux", "load_per_cpu_ceiling": 10.0,
              "source": "owner ruling 2026-11-02, skills/cmux-cells §2 (CELLS only)",
              "note": "load up to 8-10x the CPU count is NORMAL on a cell; the laptop rule here would "
                      "refuse healthy dispatches"},
}


def _platform() -> str:
    return "macos" if sys.platform == "darwin" else "linux"


def _census(mods: Modules, args: Dict[str, Any]) -> Dict[str, Any]:
    repos = args.get("repos") or ["daniel-ospina/tortoise"]
    payload: Dict[str, Any] = {"measured_at": _now(), "repos": {}, "box": {}}
    for repo in repos:
        ran = run_module(mods, "beta_progress", ["--repo", str(repo), "--json"], timeout=180.0)
        data, why = parse_json(ran, "the P0/P1 census for %s" % repo)
        payload["repos"][str(repo)] = data if data is not None else {"unmeasured": why}
    if args.get("capacity", True):
        ran = run_module(mods, "capacity", ["probe"], timeout=120.0)
        payload["box"]["capacity"] = {
            "measured_at": _now(), "exit_code": ran.rc, "stdout": ran.stdout,
            "stderr": ran.stderr, "truncated": ran.truncated,
            "outcome": "MEASURED" if ran.ok() else "UNMEASURED",
            "unmeasured": None if ran.ok() else ran.unmeasured(),
            "source": "scripts/orchestrator-harness/capacity.sh probe",
            "note": "a PLACEMENT gate (refuses to ADD work at CAP_LPC_CEILING=8.00 LPC) — never this "
                    "box's health",
        }
    if args.get("box", True):
        ran = run_module(mods, "box_status", [], timeout=120.0)
        payload["box"]["status"] = {
            "measured_at": _now(), "exit_code": ran.rc, "stdout": ran.stdout,
            # ⛔ EXIT 2 IS PART OF THE ANSWER: an unreadable identity is CANNOT-VERIFY, never
            # "nothing to report".
            "outcome": "MEASURED" if ran.rc == 0 else "CANNOT-VERIFY",
            "exit_2_means": "cannot verify — a harness identity or the process table could not be read",
            "source": "scripts/orchestrator-harness/box-status.sh",
        }
    try:
        load1, load5, load15 = os.getloadavg()
        cpus = os.cpu_count() or 1
        lpc = round(load1 / cpus, 2)
    except OSError as exc:
        payload["box"]["load"] = "UNMEASURED(os.getloadavg + %s)" % exc
    else:
        cal = PLATFORM_CALIBRATION[_platform()]
        payload["box"]["load"] = {
            "value": load1, "load_1_5_15": [load1, load5, load15], "cpus": cpus, "lpc": lpc,
            "measured_at": _now(), "source": "os.getloadavg()",
            "platform": cal["platform"], "applicable_ceiling_lpc": cal["load_per_cpu_ceiling"],
            "applicable_threshold_source": cal["source"], "calibration_note": cal["note"],
            "over_applicable_ceiling": lpc > cal["load_per_cpu_ceiling"],
            # ⛔ Load is a CLOCK reading, not a STATE reading, and on this box the fleet IS the load.
            "caveat": "a moment's reading, not a state — re-measure at the moment of a decision",
        }
    return payload


def _pr_queue(mods: Modules, args: Dict[str, Any]) -> Tuple[bool, Dict[str, Any]]:
    pr_argv = ["--json"]
    repo = args.get("repo") or os.environ.get("PR_STATE_REPO")
    if repo:
        pr_argv += ["--repo", str(repo)]
    if args.get("limit"):
        pr_argv += ["--limit", str(int(args["limit"]))]
    if args.get("pr"):
        pr_argv += ["--only", str(int(args["pr"]))]
    ran = run_module(mods, "pr_state", pr_argv, timeout=400.0, cap=400_000)
    rows, why = parse_json(ran, "the PR queue")
    if rows is None:
        # ⛔ AN UNREADABLE BOARD IS NOT AN EMPTY BOARD: exit 2 is "the pass could not be made".
        return True, {"measured_at": _now(), "unmeasured": why, "repo": repo,
                      "exit_code": ran.rc,
                      "note": "UNMEASURED — an unreadable board is not an empty queue"}
    if isinstance(rows, dict):
        picked = rows.get("rows")
        if picked is None:
            picked = rows.get("prs")
        if picked is None:
            # ⛔ A SHAPE NOBODY RECOGNISES IS NOT AN EMPTY QUEUE (review P2, invariant 1): the old
            # fall-through answered `row_count: 0, isError: false` for a payload it did not understand.
            return True, {"measured_at": _now(), "repo": repo,
                          "unmeasured": "UNMEASURED(%s -> shape + expected a list or {\"rows\": [...]}; "
                                        "got a dict with keys %s)" % (ran.cmd, sorted(rows.keys())[:8]),
                          "exit_code": ran.rc}
        rows = picked
    # ⛔ THE SHAPE REFUSAL HAS TO COVER EVERY SHAPE, NOT THE ONE IT WAS WRITTEN FOR (review cycle 2,
    # P2). Gating only `dict WITHOUT rows/prs` left `{"rows": "nope"}`, `{"rows": {}}`, a bare JSON
    # scalar and a list of non-dicts still falling into the loop below and answering
    # `row_count: 0, isError: false` — the exact reading this refusal exists to kill. Required now:
    # the top level is a dict or a list, and whatever we picked is a LIST. An empty list stays a real
    # answer (an empty board is a measurement); anything unrecognised is an abstention.
    if not isinstance(rows, (dict, list)):
        return True, {"measured_at": _now(), "repo": repo,
                      "unmeasured": "UNMEASURED(%s -> shape + expected a list or {\"rows\": [...]}; "
                                    "got %s)" % (ran.cmd, type(rows).__name__),
                      "exit_code": ran.rc}
    if not isinstance(rows, list):
        return True, {"measured_at": _now(), "repo": repo,
                      "unmeasured": "UNMEASURED(%s -> shape + expected {\"rows\": [...]} to carry a "
                                    "LIST; got %s)" % (ran.cmd, type(rows).__name__),
                      "exit_code": ran.rc}
    # ⛔ A LIST OF NON-DICTS IS NOT A QUEUE OF ROWS. Skipping the bad elements answered
    # `row_count: 0` for `[1,2,3]` — the same confident empty reading, one shape further out. It is
    # now an explicit abstention: a payload whose rows are not objects cannot be counted, and
    # "zero rows matched" must never be the report for "I could not read these rows".
    if any(not isinstance(row, dict) for row in rows):
        return True, {"measured_at": _now(), "repo": repo,
                      "unmeasured": "UNMEASURED(%s -> shape + expected a list of row objects; got a "
                                    "list whose elements include %s)"
                                    % (ran.cmd, sorted({type(r).__name__ for r in rows
                                                        if not isinstance(r, dict)})),
                      "exit_code": ran.rc}
    out_rows = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        action = row.get("action") or row.get("ACTION")
        out_rows.append(dict(row, **{"class": PR_CLASS_VIEW.get(str(action), "UNMAPPED"),
                                     "action": action,
                                     "class_is_a_view": True}))
    payload: Dict[str, Any] = {
        "measured_at": _now(), "repo": repo, "rows": out_rows,
        "row_count": len(out_rows), "exit_code": ran.rc,
        "source": "tools/fleet/pr_state.py --json",
        "vocabulary": {"classes": sorted(set(PR_CLASS_VIEW.values())) + ["UNMAPPED"],
                       "note": "the 6 classes are a VIEW; pr_state's 15 actions remain the answer "
                               "(inventory §13 Q4)"},
        "classes_unmapped": sum(1 for r in out_rows if r["class"] == "UNMAPPED"),
    }
    if args.get("closing"):
        if not args.get("pr"):
            payload["closing"] = "UNMEASURED(closing + needs `pr`: a per-PR read, never a sweep)"
        else:
            payload["closing"] = _closure_audit(mods, {"pr": args["pr"], "repo": repo})[1]
    return False, payload


def _closure_audit(mods: Modules, args: Dict[str, Any]) -> Tuple[bool, Dict[str, Any]]:
    """`closingIssuesReferences` + each issue's OWN live `state` — the comparison nothing else makes."""
    pr, repo = int(args["pr"]), str(args["repo"])
    payload: Dict[str, Any] = {"measured_at": _now(), "pr": pr, "repo": repo}
    gh = _gh()
    view = run([gh, "pr", "view", str(pr), "--repo", repo, "--json",
                "number,state,mergedAt,title,body,headRefName,closingIssuesReferences"], timeout=90.0)
    data, why = parse_json(view, "the PR view")
    if data is None:
        payload["unmeasured"] = why
        return True, payload
    refs = data.get("closingIssuesReferences") or []
    closed, still_open, unreadable = [], [], []
    for ref in refs:
        num = ref.get("number")
        if num is None:
            continue
        got = run([gh, "issue", "view", str(num), "--repo", repo, "--json", "number,state"],
                  timeout=60.0)
        issue, iwhy = parse_json(got, "issue #%s" % num)
        if issue is None:
            unreadable.append({"issue": num, "unmeasured": iwhy})
        elif str(issue.get("state")).upper() == "CLOSED":
            closed.append({"issue": num, "state": issue.get("state")})
        else:
            # ⛔ AN `open` ISSUE IS NEVER MERGED/CLOSED/DONE (invariant 2): the issue's own re-read state
            # decides, not the PR's claim to close it.
            still_open.append({"issue": num, "state": issue.get("state")})
    prose = "%s\n%s\n%s" % (data.get("title") or "", data.get("body") or "",
                            data.get("headRefName") or "")
    mentioned = sorted({int(n) for n in _numbers(prose)})
    ref_nums = {int(r.get("number")) for r in refs if r.get("number") is not None}
    payload.update({
        "state": data.get("state"), "merged_at": data.get("mergedAt"),
        "closing_references": sorted(ref_nums),
        "closed": closed, "still_open": still_open, "unreadable": unreadable,
        # ⛔ THE FALSE-MERGED DEFECT AS A FIELD: a `#N` MENTION is not a closure.
        "mentioned_but_not_closing": [n for n in mentioned if n not in ref_nums],
        "mention_is_not_a_closure": True,
        "ancestry_note": "the rail squash-merges, so a batch's constituents stay OPEN — ancestry would "
                         "report a false 'not merged' for every batched PR",
        "source": "gh pr view --json closingIssuesReferences + gh issue view --json state",
    })
    return (bool(unreadable) or bool(still_open)), payload


def _numbers(text: str) -> List[str]:
    import re
    return re.findall(r"#(\d{3,6})", text or "")


_SAVED_MAX_MATCHES = 10


def _saved_for_issue(repo: str, issue: int) -> Dict[str, Any]:
    """Saved work for one issue, read from the EXISTING `refs/wip/*` population.

    ⛔ THIS READS; IT NEVER SAVES. `scripts/bg-rescue-wip.sh` is the actuator that archives
    uncommitted work to `refs/wip/<branch-slug>` on origin. This is the lookup that makes those
    snapshots findable, so an agent asking "is this claimed?" is not told `free` while a snapshot
    of the same work sits unreferenced. No write path exists here, by design (#3489's sibling).

    The slug is derived from the BRANCH, not from the issue, so a match is a slug TOKEN equal to
    the issue number (`ai-3194` matches 3194; `ai-31940` does not). That is a heuristic, and the
    payload says so in `match_rule` — it is evidence of a candidate, never membership.

    ⛔ An unreadable registry is `UNMEASURED(<cmd> + <error>)`, NEVER `none`. An empty set is not
    evidence of absence (invariant 1) — and this is exactly the shape of the 222-snapshot problem:
    the snapshots existed the whole time; nothing was looking.
    """
    base: Dict[str, Any] = {
        "measured_at": _now(),
        "match_rule": "refs/wip/<slug> where <slug> contains the issue number as a hyphen-delimited token",
        # The save only happens when an agent exits through the normal path. A box that is killed
        # (OOM) or a cell that is reclaimed loses its work with no snapshot at all, so `none` must
        # never be read as "no work was in progress".
        "save_coverage": "normal-exit-only",
        "coverage_note": ("a snapshot exists only when the agent exited normally; an OOM kill or a "
                          "reclaimed server saves nothing, so `none` does NOT mean no work was in progress"),
    }
    if not os.path.isdir(repo):
        return dict(base, count=None,
                    unmeasured="UNMEASURED(git -C %s ls-remote origin refs/wip/*): not a directory — "
                               "the saved-work read needs a checkout, not a remote URL" % repo)
    ran = run(["git", "-C", repo, "ls-remote", "--refs", "origin", "refs/wip/*"], timeout=60.0)
    if ran.rc != 0:
        return dict(base, count=None,
                    unmeasured="UNMEASURED(git -C %s ls-remote origin refs/wip/* + %s)"
                               % (repo, (ran.stderr or "rc=%d" % ran.rc).strip()[:200]))
    total = 0
    matches: List[Tuple[str, str]] = []
    for line in (ran.stdout or "").splitlines():
        parts = line.split()
        if len(parts) != 2 or not parts[1].startswith("refs/wip/"):
            continue
        total += 1
        slug = parts[1][len("refs/wip/"):]
        if str(issue) in slug.split("-"):
            matches.append((parts[0], slug))
    found: List[Dict[str, Any]] = []
    # ⛔ THE SAVED-WORK READ NEVER WRITES THE CALLER'S CHECKOUT. It used to `git fetch` into
    # `refs/wip-remote/<slug>` INSIDE `repo`, which creates/updates local refs and downloads their
    # objects — an ENVIRONMENT MUTATION by a tool annotated `readOnlyHint: true` and described as
    # "Read-only.", and one `--read-only` could not refuse because `_claim_check` takes no mode. (It
    # also degraded to UNMEASURED on a checkout the server may not write, for a question that needed
    # no write.) A PRIVATE bare repo answers every question below with the caller's repo untouched.
    # ⛔ AND THE URL IS RESOLVED THE WAY THE CALLER'S REPO WOULD RESOLVE IT, OR THE ANSWER MOVES. A
    # RELATIVE remote (`../origin.git`) is resolved by git against the process cwd, so fetching it from
    # the scratch dir would look in the wrong place and turn a previously-measured snapshot into
    # UNMEASURED — the read-only fix must not buy its safety with a behaviour change. A relative path
    # is absolutised against the caller's checkout; a URL with a scheme (or scp-style `host:`) is passed
    # through untouched. Declared limit: URL-rewriting config in the caller's repo
    # (`url.<base>.insteadOf`) is NOT applied — an absolutised path cannot be rewritten wrongly, and a
    # remote that needs it reports UNMEASURED rather than a guess.
    scratch: Optional[str] = None
    url = ""
    fetch_fault = ""
    if matches:
        got_url = run(["git", "-C", repo, "remote", "get-url", "origin"], timeout=30.0)
        url = (got_url.stdout or "").strip() if got_url.rc == 0 else ""
        if url and "://" not in url and not re.match(r"^[^/]+\.?[^/]*:", url):
            # no scheme and no scp-style `host:` — a filesystem path, possibly relative
            url = os.path.abspath(os.path.join(repo, url))
        if not url:
            fetch_fault = ("UNMEASURED(git -C %s remote get-url origin + %s)"
                           % (repo, (got_url.stderr or "rc=%d" % got_url.rc).strip()[:120]))
        else:
            scratch = tempfile.mkdtemp(prefix="orch-mcp-wip-")
            init = run(["git", "init", "-q", "--bare", scratch], timeout=30.0)
            if init.rc != 0:
                fetch_fault = ("UNMEASURED(git init --bare <scratch> + %s)"
                               % ((init.stderr or "rc=%d" % init.rc).strip()[:120]))
                shutil.rmtree(scratch, ignore_errors=True)
                scratch = None
    try:
        for sha, slug in matches[:_SAVED_MAX_MATCHES]:
            entry: Dict[str, Any] = {"ref": "refs/wip/%s" % slug, "slug": slug, "sha": sha}
            if scratch is None:
                entry["age"] = fetch_fault
                entry["files"] = None
                found.append(entry)
                continue
            local = "refs/wip/%s" % slug
            got = run(["git", "-C", scratch, "fetch", "-q", "--no-tags", url,
                       "+refs/wip/%s:%s" % (slug, local)], timeout=60.0)
            if got.rc != 0:
                entry["age"] = ("UNMEASURED(git fetch +refs/wip/%s + %s)"
                                % (slug, (got.stderr or "rc=%d" % got.rc).strip()[:120]))
                entry["files"] = None
                found.append(entry)
                continue
            ts = run(["git", "-C", scratch, "log", "-1", "--format=%ct", local], timeout=30.0)
            if ts.rc == 0 and (ts.stdout or "").strip().isdigit():
                entry["age"] = _age(float((ts.stdout or "").strip()))
                entry["committed_at"] = _iso(float((ts.stdout or "").strip()))
            else:
                entry["age"] = ("UNMEASURED(git log -1 --format=%%ct %s + %s)"
                                % (local, (ts.stderr or "rc=%d" % ts.rc).strip()[:120]))
            # ⛔ `--root` AND `-m` ARE BOTH LOAD-BEARING, AND FOR TWO DIFFERENT SNAPSHOT SHAPES.
            # `--root` covers the ROOT-commit shape (the actuator commits a bare tree, so a
            # parent-relative diff fails with "unknown revision" and every file count would be
            # UNMEASURED on the snapshots that matter most). `-m` covers the MERGE shape: a rescue
            # snapshot is committed with `-p HEAD -p <previous snapshot>`, so a SECOND rescue — the
            # grace work, the one worth finding — is a MERGE, and `git diff-tree` prints NOTHING for a
            # merge without `-m`, with rc=0. That published `file_count: 0` as a MEASURED zero for
            # exactly the wrong shape (invariant 1: unknown is not zero). Lines are de-duplicated
            # because `-m` emits one change set PER PARENT.
            files = run(["git", "-C", scratch, "diff-tree", "--no-commit-id", "--name-only", "-r",
                         "-m", "--root", local], timeout=30.0)
            if files.rc == 0:
                entry["files"] = sorted({f for f in (files.stdout or "").splitlines() if f.strip()})
                entry["file_count"] = len(entry["files"])
            else:
                entry["files"] = None
                entry["file_count"] = None
                entry["file_count_detail"] = ("UNMEASURED(git diff-tree --root -m %s + %s)"
                                              % (local, (files.stderr or "").strip()[:120]))
            found.append(entry)
    finally:
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)
    return dict(base,
                count=len(matches),
                population=total,
                matches=found,
                truncated=len(matches) > _SAVED_MAX_MATCHES,
                note=("none" if not matches else "saved work exists for this item — read it before "
                      "redoing it") if matches else "none",
                none_means="no snapshot was found for this issue — NOT 'no work was in progress'; "
                           "see save_coverage")


def _claim_check(mods: Modules, args: Dict[str, Any]) -> Tuple[bool, Dict[str, Any]]:
    repo = args.get("repo") or os.environ.get("CLAIM_REPO")
    if not repo:
        # ⛔ A TYPED REFUSAL, NOT A FAILED READ: `claim_lanes.py` never uses the cwd implicitly, so with no
        # repo there is nothing to read — and "I was not told where to look" must not read as "no claims".
        return True, {"measured_at": _now(), "refused": "repo-required",
                      "note": "pass `repo` (or set CLAIM_REPO): the reader never uses the cwd implicitly, "
                              "and an unqueried registry is not freedom"}
    argv = ["--json", "--repo", str(repo)]
    # ⛔ A BARE READ, ALWAYS. `--pr`/`--sha` narrow the HEAD axis and would HIDE the issue-keyed claims
    # this tool also answers; the filter below is applied to the full claim list, and the reader's own
    # `readable`/`present`/`siblings` fields travel with it so an absence can never read as freedom.
    ran = run_module(mods, "claim_lanes", argv, timeout=120.0)
    data, why = parse_payload(ran, "the ref-claim registry")
    if data is None:
        return True, {"measured_at": _now(), "unmeasured": why, "exit_code": ran.rc}
    claims = data.get("claims") or []
    out: Dict[str, Any] = {
        "measured_at": _now(),
        "source": data.get("source"),
        "readable": data.get("readable"),
        "present": data.get("present"),
        "read_detail": data.get("read_detail"),
        "reader_limits": data.get("reader_limits"),
        "advisory": data.get("advisory"),
        "verdict": data.get("verdict"),
        "abstention": True,
        "abstention_note": ("EVERY claim verdict is an abstention: a claim asserts a declared OWNERSHIP "
                            "window (never that a process is alive), and an absent key is HEAD-scoped and "
                            "transient — so it is never freedom"),
        "exit_code": ran.rc,
    }
    if args.get("issue") is not None:
        want = str(int(args["issue"]))
        mine = [c for c in claims if c.get("kind") == "issue" and str(c.get("issue")) == want]
        out["issue"] = int(args["issue"])
        out["issue_claims"] = mine
        out["issue_present"] = bool(mine)
        # ⛔ CLAIMED-OR-NOT IS HALF THE ANSWER. 222 snapshots of half-finished work sat on origin
        # with nothing pointing at them, so "free" was returned while the same work had already been
        # done once. The saved-work axis is READ here and never written (the actuator is
        # bg-rescue-wip.sh); an unreadable registry is UNMEASURED, never `none`.
        out["saved"] = _saved_for_issue(str(repo), int(args["issue"]))
    if args.get("pr") is not None or args.get("sha"):
        heads = [c for c in claims if c.get("kind") == "head"]
        if args.get("pr") is not None:
            heads = [c for c in heads if str(c.get("pr")) == str(int(args["pr"]))]
        if args.get("sha"):
            heads = [c for c in heads if str(c.get("sha12", "")).startswith(str(args["sha"])[:12])]
        out["head_claims"] = heads
        out["head_present"] = bool(heads)
    # ⛔ EXIT 3 FROM THE READER = "nothing established" (an abstention, reported as a FIELD); exit anything
    # else, or `readable: false`, means the namespace could not be consulted — and THAT is an error, because
    # an unconsultable registry must never read as "nobody holds it".
    if ran.rc not in (0, 3):
        out["unmeasured"] = ran.unmeasured()
        return True, out
    out["nothing_established"] = ran.rc == 3
    return (not data.get("readable")), out


BRANCH_SLUG_KEEP = 60


def _branch_slug(branch: str) -> str:
    out = []
    for ch in branch:
        out.append(ch if (ch.isalnum() or ch in "-._") else "-")
    return "".join(out)[:BRANCH_SLUG_KEEP]


def _dispatch(mods: Modules, args: Dict[str, Any], read_only: bool) -> Tuple[bool, Dict[str, Any]]:
    if read_only:
        return True, {"refused": "read-only",
                      "note": "the server is in --read-only mode; lane.dispatch is mutating"}
    payload: Dict[str, Any] = {"measured_at": _now()}
    worktree = str(args["worktree"])
    if args.get("env"):
        # ⛔ NEVER SILENTLY DROPPED. `nonblocking-dispatch.sh` takes no `--env`, and an `export` inside a
        # tool call cannot reach the agent's own gates (they read the AGENT process) — inventory §7.2.
        payload["env"] = ("UNSUPPORTED(env + nonblocking-dispatch.sh accepts no --env: the only path that "
                          "reaches the agent's gates is the launcher's own environment; nothing was "
                          "exported and the dispatch was NOT made)")
        return True, payload
    if args.get("branch"):
        branch = str(args["branch"])
        exists = run(["git", "-C", worktree, "rev-parse", "--verify", "--quiet",
                      "refs/heads/%s" % branch], timeout=30.0)
        claimed = run(["git", "-C", worktree, "ls-remote", "--heads", "origin", branch], timeout=60.0)
        remote_exists = bool(claimed.stdout.strip()) if claimed.ok() else None
        # ⛔ THREE-VALUED, NOT TWO (review P2). `remote_exists is None` means THE PROBE FAILED, and the
        # old code fell through to dispatch — the guard disappearing exactly when it could not be
        # evaluated, which is when a collision is most likely.
        # ⛔ ORDER MATTERS: a branch the LOCAL probe FOUND is `branch-exists` whatever the remote says;
        # only an ABSENT local answer makes an unreadable remote a refusal. (My first version got this
        # order wrong and the existing branch-exists test caught it.)
        # ⛔ "MEASURED" IS NOT "rc == 0" (review cycle 2, P1). `git rev-parse --verify --quiet
        # refs/heads/<branch>` answers **rc=1 for a MEASURED ABSENCE** — that is how it says "no such
        # branch", not a failure. Treating `not exists.ok()` as unreadable inverted this guard: it
        # refused every brand-new branch (the normal dispatch) and, worse, reported a branch that the
        # remote probe could SEE (`remote: true` in the same payload) as "unmeasured".
        local_measured = (not exists.error) and (not exists.timed_out) and exists.rc in (0, 1)
        local_has = local_measured and exists.rc == 0 and bool(exists.stdout.strip())
        if not local_has and (remote_exists is None or not local_measured):
            payload["refused"] = "branch-existence-unmeasured"
            payload["branch"] = branch
            # ⛔ `exists.ok()` IS NOT "MEASURED" (review cycle 3, P2): rc=1 is a MEASURED ABSENCE, so
            # labelling by `ok()` sent the reader to debug a local probe that had answered correctly,
            # while the arm that actually needed fixing was the remote. The decision was right and the
            # field lied about why.
            payload["local"] = exists.unmeasured() if not local_measured else False
            payload["remote"] = (claimed.unmeasured() if remote_exists is None
                                 else bool(claimed.stdout.strip()))
            payload["note"] = ("the branch-existence probe could not be read, so 'free' cannot be "
                               "asserted — a dispatch here could collide with a branch that already "
                               "exists, which is the silent-actuator failure this refusal types")
            return True, payload
        if (exists.ok() and exists.stdout.strip()) or remote_exists:
            # ⛔ A TYPED REFUSAL FOR A MEASURED SILENT-ACTUATOR FAILURE: `fatal: a branch named
            # 'p0-10000' already exists` used to reach the caller as stderr prose.
            payload["refused"] = "branch-exists"
            payload["branch"] = branch
            payload["local"] = bool(exists.ok() and exists.stdout.strip())
            payload["remote"] = remote_exists if remote_exists is not None else claimed.unmeasured()
            return True, payload
    brief = str(args["brief"])
    if not os.path.isfile(brief):
        payload["refused"] = "brief-not-a-file"
        payload["brief"] = brief
        return True, payload
    argv = [str(args["name"]), worktree, brief]
    if args.get("backstop_s"):
        argv.append(str(int(args["backstop_s"])))
    if args.get("kind"):
        argv.append(str(args["kind"]))
    ran = run_module(mods, "nonblocking_dispatch", argv, timeout=180.0)
    payload.update({"argv": ran.argv, "exit_code": ran.rc, "stdout": ran.stdout,
                    "stderr": ran.stderr,
                    # ⛔ STRING KEYS, because the wire form is JSON and JSON object keys are strings —
                    # an int-keyed map answers `refusal_vocabulary[80]` in-process and
                    # `["80"]` to a real client, i.e. two shapes for one answer.
                    "refusal_vocabulary": {str(k): v for k, v in DISPATCH_REFUSALS.items()}})
    if ran.rc in DISPATCH_REFUSALS:
        payload["refused"] = DISPATCH_REFUSALS[ran.rc]
        return True, payload
    if not ran.ok() and ran.rc != 0:
        payload["unmeasured"] = ran.unmeasured()
        return True, payload
    # ⛔ THE PID COMES FROM THE `.pid` FILE, NEVER FROM THE LAUNCHER'S STDOUT. The measured failure was
    # `launcher did not report a pid: ''` — a launcher that exits 0 having written nothing.
    o = os.environ.get("O") or os.path.join(
        os.environ.get("CELL_HOME") or os.environ.get("HOME") or os.path.expanduser("~"),
        "orchestrator")
    pid_file = os.path.join(o, "bg", "%s.pid" % args["name"])
    try:
        with open(pid_file) as fh:
            pid = fh.read().strip()
    except OSError as exc:
        payload["refused"] = "no-pid"
        payload["pid_file"] = pid_file
        payload["pid_file_error"] = "%s: %s" % (type(exc).__name__, exc)
        return True, payload
    if not pid.isdigit():
        payload["refused"] = "no-pid"
        payload["pid_file"] = pid_file
        payload["pid_file_error"] = "contents are not a pid: %r" % pid[:40]
        return True, payload
    payload["pid"] = int(pid)
    payload["log"] = os.path.join(o, "bg", "%s.log" % args["name"])
    payload["worktree"] = worktree
    return False, payload


ALLOWLIST = {
    # ⛔ A DECLARED ALLOWLIST IS WHAT MAKES THE MODE MEAN ANYTHING (inventory §13 Q5). Each entry is a
    # (program, fixed-prefix args) pair, and the REST of the argv must be literal values — never a
    # pipeline, never a redirection, because there is no shell to interpret one.
    "uname": ([], 2),
    "uptime": ([], 1),
    "hostname": ([], 1),
    "whoami": ([], 1),
    "id": ([], 1),
    # ⛔ THE PREFIX IS ENFORCED (see `_allowlisted`), SO IT MUST MEAN SAFETY, NOT FORMATTING. `df`,
    # `df`, `free` and (then-admitted) `ps` were the entries where the prefix was a PRETTY-PRINTING
    # default rather than a safety property: enforcing it refused `df /`, `free -h` and `ps -ef` —
    # read-only calls, refused
    # with a reason naming neither. `max_args` is the real limit for all three, and none of them mutates
    # state from an operand (`df /` QUERIES that filesystem). `ps` was removed afterwards — see the
    # removal note below; its `max_args` bound is history, not a live limit.
    # ⛔ THE PREFIX MECHANISM IS KEPT AND IS NOT DEAD CODE: it is the INVARIANT that a declared fixed
    # prefix is honoured rather than unpacked and ignored (the defect that made `hostname NAME` pass),
    # and it is pinned by an arm that installs a prefixed entry and asserts the prefix is enforced — so
    # a future entry can rely on it and a future deletion of the check reds.
    "df": (None, 3),
    "free": (None, 3),
    # ⛔ `ps` AND `pgrep` USED TO SIT HERE, AND THEY DISCLOSE THE SAME SECRET CLASS `cat` DID (review
    # cycle 4, P2). `ps` was bounded only by ARG COUNT, and the BSD combined form takes an `e`:
    # `ps auxe` appends every process's ENVIRONMENT. Measured with a canary that existed only in the
    # environment and on no command line — `ps auxe` printed it. On procps, `pgrep -a --list-full`
    # similarly carries other processes' command lines, which routinely contain tokens.
    # Bounding them by flag was rejected for the same reason a path bound was rejected for `cat`: the
    # safe and unsafe spellings are one letter apart (`auxe` vs `aux`), and a rule that must enumerate
    # `-eo e`, `e`, `auxe`, `eax`, … is a rule that will miss one. Removed instead. What remains for
    # process/liveness diagnostics is metadata and counts (`df`, `free`, `ls`, `wc`, `sha256sum`,
    # `uname`, `uptime`, `id`, `whoami`, `hostname`), and lane liveness is answered by `lane.list` /
    # `lane.show`, which is the surface this server exists to provide.
    "git": (None, 8),
    "ls": (None, 6),
        # ⛔ `cat` IS DELIBERATELY NOT ALLOWLISTED (review P2). With no path bound it admitted
    # `cat /etc/shadow`, `cat ~/.pi/agent/jev-config.json` (the 0600 key store this fleet never
    # prints) and `cat -` — while the gate's own refusal text said "allowlisted for READING", a word
    # with no scope behind it. Removed rather than path-bounded: the diagnostics it served are served
    # by `ls`, `wc` and `sha256sum`, none of which can dump a file into a transcript, and on a cell
    # the legitimate paths are most of the box, so a bound would have been decorative.
    "wc": (None, 4),
    "sha256sum": (None, 4),
    # (`pgrep` travelled with `ps` — see the note above.)
}

# ⛔ THE VERB LIST IS THE BOUNDARY, NOT THE FLAG LIST (review cycle 3, P1). Three cycles tried to
# close this class by refusing a spelling — `--output`, then `--no-index` — and each time git reached
# the same capability another way: `git diff <file> <file>` IMPLIES `--no-index` whenever the operands
# are not repo pathspecs, which is ALWAYS true on a cell (measured: `cmux vm exec … pwd` → `/`, and
# `git rev-parse --is-inside-work-tree` → "not a git repository"). No flag is involved, so no flag rule
# can see it, and `_box_exec` returns stdout whatever the rc.
# So the surface admits only verbs that emit METADATA — never file CONTENT:
#   status      · the worktree summary
#   rev-parse   · object names
#   ls-files    · path names
# `diff`, `show` and `log` are REMOVED: each can print the contents of a file the caller names
# (`git diff a b`, `git show HEAD:path`, `git log -p -- path`), which is the `cat` capability wearing an
# allowlisted program. Diagnostics that genuinely need a diff belong in a lane's own shell, not in a
# model-facing exec surface whose whole contract is "allowlisted for READING".
GIT_OK_VERBS = ("status", "rev-parse", "ls-files")
# ⛔ `DISK_OK_VERBS` USED TO SIT HERE AND WAS REFERENCED NOWHERE (review finding, P2). Every verb it
# would have gated passes `None` as its prefix, so it constrained nothing while reading like an
# enforced rule — a reader could trust it or delete it and the behaviour was identical. Deleted rather
# than wired in: `ls` is bounded by `max_args`, which is the limit that actually applies.
# ⛔ `--output` IS A FILE WRITE, AND THE ALLOWLIST GATES THE VERB ONLY. MEASURED BEFORE THE VERB
# BOUNDARY (when `show`/`log`/`diff` were still admitted): `git show --output=/tmp/x HEAD` → rc=0,
# 7762 B written; `git log --output=/tmp/x -1` → 2038 B. Those verbs are NOT admitted any more, so that
# route is closed twice over; the token rule is kept because it REFUSES BY SHAPE — it fires on any verb
# that ever takes a caller-named output, including one re-admitted later. `cat` was the same escape in
# reverse (plant content, read it back).
# The check is a REFUSAL BY SHAPE, before the verb check, so it also covers a future verb added above.
# ⛔ AND IT IS SCOPED TO `git`, WHICH IS THE ONLY ALLOWLISTED PROGRAM IN THIS SET WITH A CALLER-NAMED
# OUTPUT FILE. A blanket ban false-blocked a READ-ONLY call and stated a falsehood doing it: GNU
# `df --output=FIELD_LIST` only selects COLUMNS (`df --output=source` writes nothing), so a legitimate
# diagnostic was refused with "writes a file the caller names" — wrong about the command and wrong
# about the reason. Scope the ban to the program whose option actually behaves that way.
WRITE_ESCAPE_TOKENS = ("--output", "--outfile", "-output")
# ⛔ `--no-index` READS ARBITRARY FILES BACK, SO REMOVING `cat` CLOSED NOTHING ON ITS OWN (review cycle
# 2, P1). MEASURED BEFORE THE VERB BOUNDARY: `["git","diff","--no-index","<home>/.pi/agent/jev-config.json",
# "/dev/null"]` passed the allowlist, hardened intact, needed no repo, and `_box_exec` returns
# `ran.stdout` regardless of rc — so the whole file (the 0600 key store included) landed in the response.
# The verb is refused now, so this token rule is BELT-AND-BRACES: it refuses BY SHAPE and therefore
# covers any content-emitting verb that is ever re-admitted, without depending on that verb's identity.
READ_ESCAPE_TOKENS = ("--no-index",)
# ⛔ A THIRD SHAPE: THESE FLAGS MAKE GIT EXECUTE A PROGRAM. `--ext-diff` runs `diff.external` (or a
# `diff.<driver>.command`) and `--textconv` runs a `textconv` driver — both NAMED IN THE TARGET REPO's
# config / `.gitattributes`, i.e. chosen by anything that can write the checkout the exec lands in.
# Same class as the `["/tmp/evil/git", …]` bypass above (a caller-chosen program running under this
# surface's authority). Historically these were reached through a verb that WAS read-only, so the verb
# gate could not see them; today `diff`/`show`/`log` are refused, and these flags are refused by shape
# so a re-admitted verb inherits the refusal. Neither flag carries a shell metacharacter, so the
# metacharacter filter could never see them either.
EXEC_ESCAPE_TOKENS = ("--ext-diff", "--textconv", "--show-signature", "--remerge-diff")
# ⛔ ABBREVIATIONS ARE NOT A HOLE, AND THIS COMMENT SAID THEY WERE. `--ext-diff`/`--textconv` are
# parsed EXACT-MATCH in git's diff.c, so `--ext`, `--ext-d`, `--textc`, `--textco` all give
# `error: invalid option` (measured on git 2.43.0) — fail-closed, and `--text`/`--exclude-standard`/
# `--extended-regexp` are REAL options that a stem refusal would wrongly block (an earlier revision of
# this file refused any token starting `--ex`, and `git ls-files --others --exclude-standard` is the
# bounded-search primitive this fleet's own AGENTS.md prescribes). The exact spellings above are the
# whole flag surface; the CONFIG surface is pinned in `GIT_PIN_CONFIG`.
# ⛔ AND REFUSING TWO FLAG SPELLINGS DOES NOT CLOSE THE CLASS — THE TRIGGER IS THE TARGET REPO'S
# CONFIG, NOT A FLAG. Porcelain git runs repo-configured helpers BY DEFAULT, with no flag at all.
# Every key below NAMES A PROGRAM that a READ verb on this surface can reach TODAY, or could reach if a
# content-emitting verb returns; each is pinned to a fixed value so the program that runs (if any) is
# ours, never the repo's. The per-key annotations say which is which:
#   core.fsmonitor            -> runs on `status` (and any index read)
#   core.alternateRefsCommand -> a SHELL command, reachable only from `log --alternate-refs`; `log` is
#                                NOT an admitted verb, so nothing on this surface reaches it — pinned
#                                anyway, so a future content-emitting verb cannot arrive with this open
#   log.showSignature=true    -> turns a plain `log`/`show` into a gpg invocation; same position
#                                (neither verb is admitted), same reason to keep the pin
#   gpg.program               -> the OPENPGP verifier; `gpg.<format>.program` is a SEPARATE key per
#                                format (`git help --config` lists all three), so pinning only this
#                                one left x509/ssh signatures running a repo-named program
#   core.pager / pager.<cmd>  -> a pager is a program; `--no-pager` (GIT_GLOBAL_FLAGS) covers the
#                                per-command form too, which `core.pager` alone does not
#   core.hooksPath            -> a hook is a program (measured: `status` runs post-index-change)
# ⛔ THE LIST IS DERIVED FROM GIT'S OWN `git help --config`, FILTERED TO KEYS THAT NAME A PROGRAM AND
# TO THE VERBS `GIT_OK_VERBS` ADMITS — not from the last review finding. Program-naming keys that are
# deliberately NOT here, with the reason each is out of reach: `core.editor`, `sequence.editor`
# (commit/rebase); `notes.rewrite.<command>` (commit/amend); `gpg.ssh.defaultKeyCommand` (SIGNING —
# verification uses `gpg.ssh.program`, which IS pinned); `diff.external`, `diff.<driver>.command`,
# `diff.<driver>.textconv`, `diff.<driver>.cachetextconv` (the diff machinery — out of reach because
# `diff`/`show`/`log` are NOT ADMITTED VERBS any more, so no per-argv disarm is needed or emitted;
# the boundary is the verb list, not a flag); `completion.commands`,
# `rebase.abbreviateCommands`, `color.pager` (not executables a read verb runs); `gc.recentObjectsHook`,
# `uploadpack.packObjectsHook`, `browser.<tool>.cmd`, `man.<tool>.cmd`, `difftool.<tool>.cmd`,
# `sendemail.*Cmd`, `interactive.diffFilter` (verbs/flows `GIT_OK_VERBS` never admits — EXCEPT the
# help flow, which `--help` used to open on EVERY admitted verb and which is now refused by shape;
# `man.*` was listed here as out of reach on that reasoning and the reasoning was wrong).
# ⛔ AND TWO CLASSES ARE NOT PINNABLE AT ALL — see GIT_UNPINNABLE_KEY_RE below; they are refused rather
# than pinned. A NEW read-only verb must be re-checked against `git help --config` beside this list.
GIT_PIN_CONFIG = (
    "core.fsmonitor=",
    "core.alternateRefsCommand=",
    "log.showSignature=false",
    "gpg.program=/bin/false",
    "gpg.openpgp.program=/bin/false",
    "gpg.x509.program=/bin/false",
    "gpg.ssh.program=/bin/false",
    "core.pager=cat",
    "core.hooksPath=/dev/null",
    # DEFENCE IN DEPTH for the transport axis (the CONTROL is the fail-closed pre-check below): these
    # are the fixed-name transport/auth keys. `protocol.ext.allow=never` matters because an
    # `ext::<program>` remote URL execs that program and does NOT go through `core.sshCommand`.
    "protocol.ext.allow=never",
    "core.sshCommand=/bin/false",
    "core.gitProxy=",
    "credential.helper=",
    "http.proxy=",
)
# `--no-pager` is a GLOBAL option and the only thing that neutralises `pager.<cmd>`, which takes
# precedence over `core.pager` PER COMMAND and cannot be enumerated.
GIT_GLOBAL_FLAGS = ("--no-pager",)
# ⛔ `GIT_DIFF_VERBS`/`GIT_HOOK_FLAGS` USED TO SIT HERE, appending `--no-ext-diff --no-textconv` for
# `diff`/`log`/`show`. They are GONE: once the VERB LIST became the boundary those three stopped being
# admitted, so the constants were disjoint from `GIT_OK_VERBS` and the branch could never fire — an
# inert enforcer that still read as the protection against a config-named diff driver. Same call this
# file already made for `DISK_OK_VERBS`. Keeping it "in case the boundary loosens" would be a guard no
# test can reach and no run can exercise. If a content-emitting verb is ever re-admitted, the disarm
# comes back WITH the verb and with an arm that reds when it is removed — that is a boundary change,
# never a flag re-added silently.
# ⛔ THE CLASS THAT CANNOT BE PINNED, AND WHY ENUMERATING KEYS WAS THE WRONG SHAPE. These keys' names
# are UNBOUNDED and come from the checkout itself (a driver name in `.gitattributes`, a remote name),
# so there is nothing to write into `GIT_PIN_CONFIG`:
#   filter.<driver>.clean|smudge|process -> runs for `status` on ANY dirty path whose attributes name
#       the driver, and its STDOUT becomes the blob content (so it can also forge what that verb
#       reports). Measured: a plain `git status` in a repo with `filter.evil.clean` runs it. THIS ONE
#       IS STILL LIVE — `status` IS an admitted verb — which is why the class is refused by shape in
#       `_allowlisted` rather than left to the pins.
#   merge.<driver>.driver -> a MERGE driver, reachable only from `show --remerge-diff`, and `show` is
#       not an admitted verb. Kept in the refusal set because its KEY NAME comes from the checkout and
#       cannot be pinned; do not read it as a live reach.
#   a PARTIAL CLONE / promisor remote turns an OBJECT READ into a LAZY FETCH, which runs the repo's
#       TRANSPORT program: `core.sshCommand`, `remote.<name>.proxy`, or `remote.<name>.url =
#       ext::<program>` (the last survives pinning the helpers, which is exactly why the pins alone
#       were not a fix).
# So the exec FAILS CLOSED: the TARGET checkout's own local config is read first
# (`_repo_config_fault`), and if it declares any of these the call is refused with a typed refusal
# naming the key. Adding a key to the pin list would not close this — a driver name cannot be guessed.
GIT_UNPINNABLE_KEY_RE = re.compile(
    r"^(filter\..+\.(clean|smudge|process)|merge\..+\.driver|remote\..+\.uploadpack)$",
    re.IGNORECASE)
# ⛔ `extensions.partialClone` IS A STRING NAMING THE PROMISOR REMOTE, NOT A BOOLEAN. Sharing a
# false-set test with `remote.<name>.promisor` meant `[extensions] partialClone = false` — a real
# promisor remote whose NAME is "false" — read as "not a partial clone" and was ALLOWED (measured: git
# then fetched from that remote and ran its `remote.<name>.uploadpack` program). Presence is the
# signal, so presence refuses.
GIT_PARTIAL_CLONE_RE = re.compile(r"^extensions\.partialclone$", re.IGNORECASE)
# how `--show-origin` labels a source: `file:…`, `command line:`, `blob:…`, `standard input:`, `-`
_GIT_CONFIG_ORIGIN_RE = re.compile(r"^(file:|command line:|blob:|standard input:|-)", re.IGNORECASE)


def _git_origin_is_checkout(origin: str) -> bool:
    """Is this origin a config file INSIDE a checkout?

    ⛔ BOTH REAL SHAPES, OR THE EVIDENCE NEVER FIRES WHERE IT MATTERS. A plain checkout prints a
    RELATIVE origin — `file:.git/config` (measured on git 2.43 from the root, a subdirectory, and via
    `git -C <abs>`) — while a linked worktree prints an absolute `.git/worktrees/<n>/config`, and a
    worktree-config repo prints `…/.git/worktrees/<n>/config.worktree`. Matching only `/.git/` missed
    the commonest shape and would have reported a real checkout `unmeasured` forever.
    """
    if not origin.lower().startswith("file:"):
        return False
    path = origin[len("file:"):]
    return "/.git/" in path or path.startswith(".git/")
# only `remote.<name>.promisor` is a BOOLEAN, and only here does a false-set make sense
GIT_LAZY_FETCH_KEY_RE = re.compile(r"^remote\..+\.promisor$", re.IGNORECASE)
# ⛔ A BARE ARGUMENT TO `hostname` IS THE SETTER FORM, NOT A QUERY. `hostname NAME` and
# `hostname -F <file>` RENAME the box (`hostname --help`: `{hostname|-F file}  set host name`), and
# `ALLOWLIST["hostname"] = ([], 1)` bounds only the COUNT — so `["hostname", "pwned-cell"]` passed this
# gate, whose refusal text says the surface is "allowlisted for READING". A rename is not cosmetic on
# this fleet: `lane_registry.short_host()` is baked into every record's `host` and every minted
# `lane_id`, so that box's new records stop matching its existing ones and host-scoped claim/
# ownership reads degrade to abstentions. Queries only, by explicit flag.
HOSTNAME_OK_FLAGS = ("-a", "-A", "-d", "-f", "-i", "-I", "-s", "-y", "-V", "--version",
                     "-h", "--help")



def _repo_config_fault(cmux: str, target: str, timeout_s: int) -> Tuple[str, bool]:
    """(refusal reason, MEASURED). See GIT_UNPINNABLE_KEY_RE for why this check exists.

    ⛔ IT MUST READ THE SAME SCOPES THE VERB READS, OR IT IS THEATRE. `--local` was one scope only: a
    repo with `extensions.worktreeConfig=true` puts per-worktree keys in `.git/config.worktree`, and a
    GLOBAL `[filter "evil"] clean` plus a repo `.gitattributes` runs just as well — both are invisible
    to `--local`, and both were reproduced running under an allowlisted `git status`. So the read is
    the EFFECTIVE config (`--local` dropped), which is exactly what the verb resolves.

    ⛔ AND IT PARSES `-z`, NOT `key=value`. A config SUBSECTION may legally contain `=`, and `git
    config --list` prints `filter.a=b.clean=/tmp/x.sh` — splitting on the first `=` yields the key
    `filter.a`, which no pattern here can match, while git itself reads the driver `a=b` correctly.
    With `-z` the record separator is NUL and the key/value separator is a NEWLINE, so a key can
    contain anything.

    ⛔ AND A TRUNCATED LISTING IS A REFUSAL, NOT A CLEAN ONE. `run()` caps the read and DISCARDS the
    rest; a config with the driver past the cap (measured at byte 468123) would otherwise pass as
    clean. A read that was CUT SHORT is not evidence that nothing was declared.

    Second element is False only when the read did not happen at all (no repo at that path, or git
    failed) — the caller reports that as `unmeasured` rather than `clean`, because a control that did
    not run must not read as one that passed.
    """
    # ⛔ THE PRE-CHECK GETS THE EXEC'S OWN BUDGET. It used to ask the transport for 20 s while the
    # local kill sat at 45 s — and the transport answers FIRST (that is the whole point of
    # CHANNEL_MARGIN_S). A config read that timed out at the transport level therefore came back as an
    # ordinary `Ran` with timed_out=False and rc=124, which `rc != 0` mapped to `unmeasured`, and the
    # git command RAN with a budget 3x the one that cut the check. Same budget now, so the local kill
    # is the authority, and any non-zero status is a REFUSAL (below).
    got = run([cmux, "vm", "exec", "--timeout", str(timeout_s), target, "--",
               "git", "config", "--includes", "--list", "-z", "--show-origin"],
              timeout=timeout_s + CHANNEL_MARGIN_S, cap=MAX_CAP)
    # ⛔ PARSE WHATEVER WAS ALREADY DRAINED, BEFORE JUDGING THE READ. `run()` drains into stdout even
    # on a timeout, so a key it already printed must still refuse — discarding it would be the same
    # "cut short is clean" mistake the truncation branch exists to prevent.
    listing = (got.stdout or "")
    fault = ""
    saw_repo = False
    # `-z --show-origin` prints ORIGIN \0 KEY\nVALUE \0 ORIGIN \0 … — the origin is how we tell a
    # checkout's own config from a global/system one without a second exec.
    # ⛔ THE PAIRING IS BY SHAPE, NOT BY POSITION. A positional `tokens[k], tokens[k+1]` walk desyncs
    # on ONE foreign NUL-terminated token at the head of the stream (a transport banner — this repo
    # already documents that shape drifting between cmux builds), after which every record is read as
    # an ORIGIN, no anchored key regex can match, `saw_repo` never fires, and the scan silently reports
    # nothing. So a token is an ORIGIN only when it LOOKS like one; everything else is a record.
    tokens = listing.split("\0")
    origin = ""
    for token in tokens:
        if not token:
            continue
        if _GIT_CONFIG_ORIGIN_RE.match(token):
            origin = token
            if _git_origin_is_checkout(origin):
                saw_repo = True
            continue
        record = token
        key, _, value = record.partition("\n")
        key = key.strip()
        # ⛔ NO SECOND `saw_repo` SET HERE (review cycle 4, P2). `origin` is assigned once, above, and
        # `_git_origin_is_checkout` is pure on its argument — so by the time this branch runs, the guard
        # below could only ever re-set a value the earlier check already settled. It read as
        # evidence-gathering and changed nothing; a reader could delete it or trust it with identical
        # behaviour, which is the same class as the constants this file deleted.
        if GIT_PARTIAL_CLONE_RE.match(key):
            fault = fault or ("the target checkout declares a PARTIAL CLONE (%s): an object read can "
                              "trigger a LAZY FETCH from the promisor remote, which runs that "
                              "remote's program (`remote.<name>.uploadpack`, `core.sshCommand`, "
                              "`remote.<name>.proxy`, or an `ext::<program>` URL)" % key)
            continue
        if GIT_UNPINNABLE_KEY_RE.match(key):
            fault = fault or ("the target checkout's config names a program this surface CANNOT "
                              "neutralise (%s): a filter/merge driver is chosen by "
                              "`.gitattributes`, so its key name cannot be pinned by a `-c` "
                              "argument — the exec is refused rather than run with a program the "
                              "repo chose" % key)
            continue
        if GIT_LAZY_FETCH_KEY_RE.match(key):
            # ⛔ A VALUELESS ENTRY IS `true` IN GIT (`[remote "origin"] promisor` prints with no `=`),
            # so an empty/missing value must NOT read as false; and `off`/`n`/`f` ARE legal false
            # spellings. Only THIS key is a boolean — see GIT_PARTIAL_CLONE_RE for the string one.
            if value.strip().lower() not in ("false", "no", "off", "0", "n", "f"):
                fault = fault or ("the target checkout declares a PROMISOR remote (%s), so an object "
                                  "read can trigger a LAZY FETCH that runs a transport program" % key)
    if fault:
        return fault, True
    # ⛔ ANY NON-ZERO STATUS IS A REFUSAL. `--local` is not used (it misses worktree/global scope), so
    # `git config --list` now SUCCEEDS outside a checkout and a non-zero status means the read itself
    # failed — a transport timeout (rc 124), a missing git, a corrupt config. A read that did not
    # succeed is not evidence, and it must not fall through to the exec. `timed_out` needs no separate
    # clause: `run()` returns `rc=None` on its own kill, which this already catches (claiming
    # otherwise was a comment about an arm that could not discriminate).
    if got.error or got.rc != 0:
        detail = got.error or ("rc=%s%s" % (got.rc, (": " + (got.stderr or "").strip()[:120])
                                            if (got.stderr or "").strip() else ""))
        return ("the target checkout's config could not be READ (%s), so it cannot be checked for a "
                "program-naming key — refused rather than run with an unread config" % detail), True
    if got.truncated:
        return ("the target checkout's config listing was CUT SHORT by the %s-byte channel cap "
                "(truncated is a CHANNEL fact over stdout+stderr, not a statement about the "
                "listing), so it could not be checked for a program-naming key" % got.cap), True
    # ⛔ AND `rc 0` DOES NOT BY ITSELF PROVE A REPOSITORY WAS READ. Without `--local`, `git config
    # --list` SUCCEEDS OUTSIDE a repository (global+system scope only), so "not a checkout" would
    # report `clean` — the conflation the tri-state exists to end.
    # ⛔ THE EVIDENCE IS THE ORIGIN SHAPE, AND ONLY THAT (review cycle 5, P2). An earlier revision also
    # accepted `core.repositoryformatversion` as positive evidence; round 10 (`6b1d31e98`) deleted that
    # arm and left this sentence claiming it, so a reader could trust or delete the wrong branch with
    # identical behaviour. Consequence of the origin-only rule, stated so it is not a surprise: a
    # `--separate-git-dir` checkout keeps its config outside `/.git/`, so it reads `measured=False` and
    # is labelled `repo_config: "unmeasured"`. That is a LABEL, not an admission — the hostile-key scan
    # is origin-independent and still refuses such a checkout.
    if not saw_repo:
        return "", False
    return "", True


def _harden_argv(argv: List[str]) -> List[str]:
    """Pin git configuration that NAMES A PROGRAM, so an admitted verb cannot reach it.

    ⛔ THIS IS NO LONGER A DIFF-DISARM, AND SAYING IT WAS WOULD TEACH THE WRONG LAYER. Every admitted
    git verb (`status`, `rev-parse`, `ls-files`) runs under `GIT_PIN_CONFIG` + `GIT_GLOBAL_FLAGS`, so a
    program named in config — `core.fsmonitor`, `pager.<cmd>`, `gpg.*.program`, `core.sshCommand`,
    `core.gitProxy`, credential helpers — cannot be reached by the verb alone. That is the class behind
    the `--output`, `--no-index` and implicit-`--no-index` escapes in sequence: each closed one
    spelling, and the boundary finally moved to the VERB.

    `diff`, `log` and `show` are NOT admitted any more (they can print a file's contents — `git diff
    <file> <file>` implies `--no-index` outside a repo, and a cell's exec cwd is `/`), so the
    `--no-ext-diff --no-textconv` pair is no longer emitted here: it became inert the moment the verb
    list became the boundary, and an inert guard that reads as the protection is worse than its absence.

    `cmux vm exec` forwards no environment, so a hardened env cannot be passed: the guarantee travels
    inside the argv. `-c <key>=…` beats every config FILE (including one reached through
    `include.path`), and `--no-pager` is a GLOBAL option, so it precedes the verb.
    """
    out = list(argv)
    if not out or out[0] != "git":
        return out
    rest = out[1:]
    if not rest or rest[0] not in GIT_OK_VERBS:
        # Not a verb this module understands: `_allowlisted` refuses it, and inventing a shape for it
        # here would be a claim about a command that never runs.
        return out
    verb = rest[0]
    head: List[str] = ["git"]
    for pin in GIT_PIN_CONFIG:
        head += ["-c", pin]
    head += list(GIT_GLOBAL_FLAGS)
    out = head + [verb] + rest[1:]
    return out


# ⛔ A LINK REFUSAL IS A CHANNEL FACT, NOT THE COMMAND'S OWN rc (agent-infra#2345).
# MEASURED 2026-11-08 from `pi-cell-5`: `cmux vm ls --json` printed `"reachable":true` for all four
# peers while `cmux vm exec <peer> -- hostname` failed against all four (`rc=3`, stderr
# `cmux: link to '<peer>' exited; see ~/.cmux/peer-links/<peer>.log`). This surface then reported
# `outcome: NONZERO, rc: 3`, which reads as "the peer RAN the command and it failed" and sends the
# operator to the command — or to the peer's state — when the peer never ran anything at all.
# The three causes have three DIFFERENT remedies, and each is visible in the stderr line this surface
# already holds, so the class is named HERE instead of making every caller re-parse prose or open a log
# behind a path:
#   link-refused          the client's route/identity for the peer was refused. Measured 2026-11-03 (on
#                         the issue): the vendor's `vm exec` link path never spends the `--carrier`
#                         mode that DOES connect, so a perfectly healthy peer refuses too.
#   no-known-daemon       the same refusal in the client's own words — what `~/.cmux/peer-links/
#                         <peer>.log` holds, i.e. the line a caller is told to go read.
#   daemon-binary-absent  THIS CALLING box has no usable `cmux-tui` (#3195), so EVERY peer fails at
#                         once and the remedy is on this box — not on the peer, and not in the command.
# ⛔ rc=0 IS STILL A REFUSAL. A refusal reported with exit status 0 was measured on `pi-cell-3`
# (2026-10-23, on the issue): a caller that checks only `rc` read a dead link as success. The class is
# reported whatever the rc, so the fail-open form cannot pass as a run here either.
LINK_REFUSAL_CLASSES = (
    ("daemon-binary-absent", re.compile(r"cmux-tui daemon binary not found at (?P<path>\S+)")),
    ("link-refused", re.compile(r"^cmux: link to ['\"](?P<peer>[^'\"]+)['\"] exited", re.M)),
    ("no-known-daemon", re.compile(r"no known daemon matches this route")),
)
LINK_REFUSAL_DETAIL = {
    "link-refused":
        "the client's route/identity for this peer was refused before the peer ran anything — the "
        "peer's health is NOT what this line measured (agent-infra#2345: `vm exec` does not spend the "
        "`--carrier` mode that does connect)",
    "no-known-daemon":
        "the client holds no daemon for this route: no pairing. Routing is what failed, not the peer "
        "and not the command (agent-infra#2345)",
    "daemon-binary-absent":
        "THIS box has no usable cmux-tui, so every peer refuses — the remedy is on the calling box, "
        "not on the peer (agent-infra#3195)",
}
PEER_LOG_RE = re.compile(r"(?P<path>(?:~|/)[^\s]*peer-links/[^\s]+)")


def _link_refusal(ran: "Ran") -> Optional[Dict[str, Any]]:
    """Classify a `cmux vm exec` LINK REFUSAL, or None when the transport ran something.

    Consumes only what the transport itself answered (`stderr`/`stdout`) — never a re-probe and never
    the peer's daemon state, neither of which this surface can measure (skill §3: `timed_out` and a
    refusal are CHANNEL facts, never a box verdict).
    """
    text = "\n".join(part for part in (ran.stderr or "", ran.stdout or "") if part)
    if not text:
        return None
    for klass, rx in LINK_REFUSAL_CLASSES:
        match = rx.search(text)
        if not match:
            continue
        out: Dict[str, Any] = {
            "refused": klass,
            "outcome": "CHANNEL-REFUSED",
            "refusal": text.strip().splitlines()[0][:300],
            "refusal_detail": LINK_REFUSAL_DETAIL[klass],
            "channel_only": "a link refusal is a CHANNEL fact — the peer never ran the command, so "
                            "this rc is the TRANSPORT's, never the command's verdict",
        }
        peer = match.groupdict().get("peer")
        if peer:
            out["peer"] = peer
        log = PEER_LOG_RE.search(text)
        if log:
            out["peer_log"] = log.group("path")
        if ran.rc == 0:
            out["fail_open"] = ("the transport exited 0 while refusing the link — a caller that checks "
                                "only `rc` reads this as success (agent-infra#2345)")
        return out
    return None


def _box_exec(mods: Modules, args: Dict[str, Any], read_only: bool) -> Tuple[bool, Dict[str, Any]]:
    if read_only:
        return True, {"refused": "read-only",
                      "note": "the server is in --read-only mode; box.exec is the tool it gates hardest"}
    box = str(args.get("box") or "")
    argv = args.get("argv")
    payload: Dict[str, Any] = {"measured_at": _now(), "box": box}
    # ⛔ THE ARGV SURFACE IS THE CONTROL. A string here would be handed to `sh`, and a deny/allow rule
    # "doesn't match the same program by path or inside sh -c" (Claude Code security docs) — so a string
    # is REFUSED by TYPE, not sanitised.
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
        payload["refused"] = "argv-must-be-a-list-of-strings"
        payload["argv"] = argv
        payload["note"] = ("pass the command and its arguments as SEPARATE strings; a shell string is "
                           "refused by type because no allowlist survives `sh -c`")
        return True, payload
    allowed, why = _allowlisted(argv)
    if not allowed:
        payload["refused"] = "command-not-allowlisted"
        payload["argv"] = argv
        payload["reason"] = why
        payload["allowlist"] = sorted(ALLOWLIST)
        # FAIL-CLOSED: never a pass-through.
        return True, payload
    # ⛔ BOTH ARE CLAMPED HERE, BECAUSE THE SCHEMA DOES NOT BOUND THEM AND `run()`'s OWN CLAMP WOULD
    # OTHERWISE BE THE ONLY ONE — `timeout_s` also goes to `cmux --timeout`, which `run()` never sees.
    # A caller-supplied `86400` made a hung remote command hold a slot for a day. A degenerate value
    # falls back to the DEFAULT, never to the maximum (see `run()`).
    try:
        timeout_s = int(args.get("timeout_s") or 60)
    except (TypeError, ValueError):
        timeout_s = 60
    if not (timeout_s > 0):
        timeout_s = 60
    elif timeout_s > MAX_TIMEOUT_S:
        timeout_s = MAX_TIMEOUT_S
    try:
        cap = int(args.get("max_output") or 20_000)
    except (TypeError, ValueError):
        cap = 20_000
    if cap < 0:
        cap = 20_000
    elif cap > MAX_CAP:
        cap = MAX_CAP
    cmux = _cmux()
    if cmux is None:
        payload["unmeasured"] = "UNMEASURED(cmux vm exec + cmux not found on PATH)"
        return True, payload
    resolution = _resolve_box(cmux, box)
    payload["resolution"] = resolution
    target = resolution.get("name") or box
    if argv[0] == "git":
        # ⛔ FAIL CLOSED ON THE CLASS THAT CANNOT BE PINNED. See GIT_UNPINNABLE_KEY_RE: a filter or
        # merge driver is named by the CHECKOUT, so the only defence is to read the checkout's own
        # config and refuse. Runs before the exec, on the same box, with the same cwd.
        fault, measured = _repo_config_fault(cmux, target, timeout_s)
        if fault:
            payload["refused"] = "repo-config-names-a-program"
            payload["argv"] = list(argv)
            payload["reason"] = fault
            return True, payload
        # ⛔ TRI-STATE, because "the check passed" and "the check never ran" are different answers and
        # a caller must be able to tell them apart. Only a read that HAPPENED and found nothing is
        # `clean`.
        payload["repo_config"] = "clean" if measured else "unmeasured"
    # ⛔ THE EXECUTED ARGV IS HARDENED, AND HARDENING HAPPENS AFTER VALIDATION ON PURPOSE. `_allowlisted`
    # must bound what the CALLER sent — its `max_args` limit would otherwise be inflated by our own
    # flags, refusing or admitting on the wrong count — and the argv that actually runs is ours to
    # build. The caller's argv is reported as sent; the executed one is reported beside it whenever
    # they differ, so the transform is visible rather than implied.
    exec_argv = _harden_argv(list(argv))
    payload["argv"] = list(argv)
    if exec_argv != list(argv):
        payload["executed_argv"] = exec_argv
    ran = run([cmux, "vm", "exec", "--timeout", str(timeout_s), target, "--"] + exec_argv,
              timeout=timeout_s + CHANNEL_MARGIN_S, cap=cap)
    payload.update({
        "rc": ran.rc,
        "stdout": ran.stdout,
        "stderr": ran.stderr,
        # ⛔ CHANNEL FACTS, CARRIED AS THEMSELVES: never synthesised into `box-unreachable`, because a
        # disk-full guest answers `running` while every exec times out (skill §3).
        "timed_out": ran.timed_out,
        "truncated": ran.truncated,
        "truncated_at_bytes": cap,
        "channel_only": "timed_out and truncated are CHANNEL facts — never evidence about the box",
        "argv_executed": ran.argv,
        "source": "cmux vm exec",
    })
    if ran.error:
        payload["unmeasured"] = ran.unmeasured()
        return True, payload
    refusal = _link_refusal(ran)
    if refusal:
        # ⛔ BEFORE `timed_out` ON PURPOSE: a refusal is an ANSWER the transport gave, not a slow
        # channel, and reporting it as the command's own non-zero rc is what #2345 costs.
        payload.update(refusal)
        return True, payload
    if ran.timed_out:
        payload["outcome"] = "CHANNEL-TIMEOUT"
        return True, payload
    payload["outcome"] = "RAN" if ran.rc == 0 else "NONZERO"
    return ran.rc != 0, payload


def _allowlisted(argv: List[str]) -> Tuple[bool, str]:
    # ⛔ THE ALLOWLIST PINS A **NAME**, SO THE NAME IS EXACTLY WHAT MAY BE PASSED. Matching
    # `basename(argv[0])` let `["/tmp/evil/git", "status"]`, `["./git", "status"]` and
    # `["../../bin/git", "status"]` all pass (verified) — i.e. any file named an allowlisted program, at
    # a CALLER-CHOSEN path, executed under this surface's authority. `/tmp` on a cell is writable by
    # anything else running there, so a planted `git`/`cat`/`ls` was reachable through a gate whose own
    # contract says "a command that is not on the allowlist is a TYPED REFUSAL, never a pass-through"
    # and whose cited rationale is that a rule "doesn't match the same program by path".
    if os.sep in argv[0] or (os.altsep and os.altsep in argv[0]):
        return False, ("refusing %r: the allowlist pins a PROGRAM NAME, and a path selects a"
                       " different file than the one the name refers to" % argv[0])
    prog = argv[0]
    if prog not in ALLOWLIST:
        return False, "%r is not on the allowlist" % prog
    prefix, max_args = ALLOWLIST[prog]
    rest = argv[1:]
    if len(rest) > max_args:
        return False, "at most %d argument(s) for %r, got %d" % (max_args, prog, len(rest))
    # ⛔ THE DECLARED PREFIX IS ENFORCED, NOT DECORATION. It was unpacked and NEVER USED (only
    # reference in this function), so the `(program, fixed-prefix args)` contract the ALLOWLIST
    # comment states was unobserved: `free` required no `-m` and `ps` required no `-eo …`, so an
    # arbitrary argv of the right LENGTH passed. That is the same class as `hostname NAME` — a gate
    # that checks a count and calls it a shape.
    if prefix is not None and list(rest[:len(prefix)]) != list(prefix):
        return False, ("%r requires the fixed arguments %r first (got %r)"
                       % (prog, list(prefix), list(rest[:len(prefix)])))
    for token in argv:
        if any(ch in token for ch in "|&;><`$\n\r\\"):
            return False, "refusing %r: shell metacharacters have no meaning in an argv surface" % token
    # ⛔ A WRITE-ESCAPE IS NOT A SHELL METACHARACTER, SO THE FILTER ABOVE MISSES IT. Scoped to `git`,
    # the one allowlisted program here whose option names a caller-chosen file.
    if prog == "git":
        for token in argv:
            low = token.lower()
            for bad in WRITE_ESCAPE_TOKENS:
                if low == bad or low.startswith(bad + "="):
                    return False, ("refusing %r: %s writes a file the caller names — an argv surface "
                                   "allowlisted for READING is not a write channel" % (token, bad))
            # ⛔ A READ-BACK ESCAPE IS NEITHER A METACHARACTER NOR A WRITE (see READ_ESCAPE_TOKENS).
            # `git diff --no-index <a> <b>` dumps any readable file the caller names, needs no repo,
            # and `_box_exec` returns stdout whatever the rc — so it is the `cat` capability wearing an
            # allowlisted program, and removing `cat` did not close that class on its own (review
            # cycle 2, P1: measured on the 0600 JEV key store).
            for bad in READ_ESCAPE_TOKENS:
                if low == bad or low.startswith(bad + "="):
                    return False, ("refusing %r: %s reads a file the caller names back into the "
                                   "response — an argv surface allowlisted for READING is not a "
                                   "file-dump channel" % (token, bad))
            # ⛔ `--help` IS AN EXECUTION CHANNEL, AND IT TURNS EVERY ADMITTED VERB INTO ONE (review
            # cycle 5, P1 — measured on three verbs, from cwd `/` as well as inside a repo).
            # `git status --help` does not print text: it renders the manual through `man.<tool>.cmd` /
            # `man.viewer`, BOTH OF WHICH NAME A PROGRAM, and both are read from the repo's config (or
            # the box's global config). Measured with the module's own hardened argv — all 14 pins plus
            # `--no-pager` — in a repo declaring `man.viewer=evil` + `man.evil.cmd`: rc=0, empty stdout,
            # and the program ran. `git rev-parse --help` and `git ls-files --help` are the same.
            # ⛔ IT CANNOT BE PINNED, ONLY REFUSED: measured, `man.viewer=`, `man.viewer=man`,
            # `help.format=man`, `web.browser=` and leaving the keys unpinned ALL still ran the repo's
            # `man.evil.cmd`, so no `-c` value closes it. And `_repo_config_fault` reads that repo as
            # CLEAN, because `man.*` is not an unpinnable key class — so the fail-closed control cannot
            # see this and the refusal has to live here, by shape.
            # `-h` stays allowed: measured `rc=129`, usage text only, no program execution.
            if low == "--help" or low.startswith("--help="):
                return False, ("refusing %r: --help renders the manual through a CONFIG-NAMED program "
                               "(`man.<tool>.cmd` / `man.viewer`), so it is an execution channel, not a "
                               "read — an argv surface allowlisted for READING is not an execution "
                               "surface" % token)
            # ⛔ AND AN EXEC-ESCAPE IS NEITHER A METACHARACTER NOR A WRITE (see EXEC_ESCAPE_TOKENS).
            for bad in EXEC_ESCAPE_TOKENS:
                if low == bad or low.startswith(bad + "="):
                    return False, ("refusing %r: %s makes git EXECUTE a program named by the target "
                                   "repo's config/.gitattributes — an argv surface allowlisted for "
                                   "READING is not an execution channel" % (token, bad))
            # ⛔ INCLUDING EVERY ABBREVIATION OF THOSE TWO — actually, NOT NEEDED, and the refusal is
            # deliberately absent: git parses both EXACT-MATCH (`--ext`/`--textc` are `invalid option`,
            # measured), so a prefix cannot reach them, while `--ex`-prefixed REAL options
            # (`--exclude-standard`, `--extended-regexp`) would be false-blocked by a stem rule (an
            # earlier revision of this file did exactly that, and the arm now pins the allowed form).
    # ⛔ `hostname` WITH A BARE ARGUMENT RENAMES THE BOX (see HOSTNAME_OK_FLAGS). Flags only.
    if prog == "hostname":
        for token in rest:
            if token not in HOSTNAME_OK_FLAGS:
                return False, ("refusing %r: `hostname` takes QUERY flags only on this surface — a "
                               "bare argument (or `-F`) SETS the host name, which rewrites the "
                               "identity every lane record and lane_id is minted from" % token)
    if prog == "git" and (not rest or rest[0] not in GIT_OK_VERBS):
        return False, "git verb %r is not read-only" % (rest[0] if rest else "")
    # ⛔ `pgrep` IS NOT IN THIS TUPLE ANY MORE (review cycle 4): it was removed from the allowlist for
    # disclosing other processes' command lines, and `prog not in ALLOWLIST` already returns earlier —
    # so naming it here was residue that read as "pgrep is admitted" inside the gate itself.
    if prog in ("wc", "sha256sum") and not rest:
        return False, "%r needs an argument" % prog
    return True, ""


def _resolve_box(cmux: str, box: str) -> Dict[str, Any]:
    """LABEL → VM NAME, reported. `cmux vm <verb>` addresses the NAME column, so a label fails with an
    opaque error whose own advice ('start a new one') is a spend-flavoured remedy for a running box."""
    ran = run([cmux, "vm", "ls"], timeout=45.0)
    if not ran.ok():
        return {"given": box, "name": None,
                "unmeasured": ran.unmeasured(),
                "note": "executing with the value as given; a label that is not a name surfaces as the "
                        "transport's own error, reported verbatim"}
    names, labels = [], []
    for line in ran.stdout.splitlines():
        parts = line.split()
        if not parts:
            continue
        names.append(parts[0])
        if len(parts) > 1:
            labels.append((parts[0], parts[1:]))
    if box in names:
        return {"given": box, "name": box, "source": "cmux vm ls (exact NAME column match)"}
    for name, cols in labels:
        if box in cols:
            return {"given": box, "name": name, "source": "cmux vm ls (LABEL column match)"}
    return {"given": box, "name": None, "source": "cmux vm ls",
            "note": "no NAME and no LABEL matched — executing with the value as given and reporting the "
                    "transport's own error rather than inventing a resolution"}


def _review_record(mods: Modules, args: Dict[str, Any]) -> Tuple[bool, Dict[str, Any]]:
    pr = int(args["pr"])
    argv = ["--check-carry", str(pr)]
    if args.get("repo"):
        # ⛔ POSITIONAL. `--repo` exits 2 on this script, which is a documented refusal, not a style
        # choice (§5.0 V10).
        argv.append(str(args["repo"]))
    ran = run_module(mods, "record_review", argv, timeout=180.0, cap=100_000)
    payload: Dict[str, Any] = {"measured_at": _now(), "pr": pr, "repo": args.get("repo"),
                               "argv": ran.argv, "exit_code": ran.rc, "source":
                               "scripts/record-review.sh --check-carry (the gate's own predicate)"}
    line = ""
    for candidate in (ran.stdout or "").splitlines():
        if "\t" in candidate:
            line = candidate.strip()
            break
    if not line:
        payload["unmeasured"] = ran.unmeasured()
        return True, payload
    fields = line.split("\t")
    verdict = fields[0].strip()
    state, next_action = CARRY_VERDICTS.get(verdict, ("UNRECOGNISED", "no next action is known for this "
                                                                    "verdict — do NOT treat it as a carry"))
    payload.update({
        "verdict": verdict, "state": state, "next_action": next_action,
        "record_digest": (fields[1].strip() if len(fields) > 1 else None),
        "live_digest_or_status": (fields[2].strip() if len(fields) > 2 else None),
        "stderr": ran.stderr,
        "landing_contract": "step 1 of 5: diff hash -> ONE fresh review -> verdict comment -> record "
                            "--evidence -> rail. This tool never substitutes for step 2",
    })
    if args.get("diff_hash"):
        hran = run_module(mods, "record_review", ["--print-diff-hash", str(pr)] + (
            [str(args["repo"])] if args.get("repo") else []), timeout=120.0, cap=20_000)
        payload["live_diff_hash"] = (hran.stdout.strip() if hran.ok() else hran.unmeasured())
    # ⛔ EVERY NON-`head` VERDICT IS AN ACTION, so this surface reports `isError` for all of them — the
    # point of the tool is that a caller cannot read `carry-patch` as "reviewed".
    return verdict != "head", payload


def _reminder(mods: Modules, args: Dict[str, Any], read_only: bool) -> Tuple[bool, Dict[str, Any]]:
    action = str(args.get("action") or "")
    path = os.path.join(_state_dir(), "reminders.json")
    payload: Dict[str, Any] = {"measured_at": _now(), "action": action, "queue": path,
                               "delivery_contract": "the TURN BOUNDARY confirms delivery, never a send's "
                                                    "exit status (objective-reminder.sh's own rule)"}
    if action == "list":
        payload["reminders"] = _read_reminders(path)
        # ⛔ AN UNREADABLE QUEUE IS AN ERROR; an EMPTY one is not. `_read_reminders` returns a STRING only
        # for the unmeasured case, so that is the whole test.
        return isinstance(payload["reminders"], str), payload
    if read_only:
        payload["refused"] = "read-only"
        return True, payload
    if action == "set":
        if not args.get("message"):
            payload["refused"] = "message-required"
            return True, payload
        reminders = _read_reminders(path)
        if isinstance(reminders, str):
            payload["unmeasured"] = reminders
            return True, payload
        rid = str(args.get("id") or "r%d" % (_now(),))
        reminders[rid] = {"id": rid, "message": str(args["message"]),
                          "due_at": int(args.get("due_at") or _now()),
                          "every_s": args.get("every_s"),
                          "created_at": _now(), "state": "PENDING",
                          "delivery": "turn-boundary", "attempts": 0}
        err = _write_reminders(path, reminders)
        payload["reminder"] = reminders[rid]
        if err:
            payload["unmeasured"] = err
            return True, payload
        if args.get("install_timer"):
            ran = run_module(mods, "merge_reminder",
                             ["--install-timer", "--interval", str(int(args.get("every_s") or 600))],
                             timeout=120.0)
            payload["timer"] = {"exit_code": ran.rc, "stdout": ran.stdout, "stderr": ran.stderr,
                                "source": "merge-reminder.py --install-timer (launchd / systemd user "
                                          "timer)",
                                "outcome": "INSTALLED" if ran.ok() else "UNMEASURED",
                                "unmeasured": None if ran.ok() else ran.unmeasured()}
            return (not ran.ok()), payload
        return False, payload
    if action == "cancel":
        reminders = _read_reminders(path)
        if isinstance(reminders, str):
            payload["unmeasured"] = reminders
            return True, payload
        rid = str(args.get("id") or "")
        gone = reminders.pop(rid, None)
        if gone is None:
            payload["refused"] = "no-such-reminder"
            payload["id"] = rid
            return True, payload
        err = _write_reminders(path, reminders)
        payload["cancelled"] = gone
        if err:
            payload["unmeasured"] = err
            return True, payload
        if args.get("install_timer"):
            ran = run_module(mods, "merge_reminder", ["--uninstall-timer"], timeout=120.0)
            payload["timer"] = {"exit_code": ran.rc, "outcome": "UNINSTALLED" if ran.ok()
                                else "UNMEASURED", "unmeasured": None if ran.ok() else ran.unmeasured()}
            return (not ran.ok()), payload
        return False, payload
    payload["refused"] = "unknown-action"
    payload["allowed"] = ["set", "list", "cancel"]
    return True, payload


def _read_reminders(path: str) -> Any:
    try:
        with open(path) as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        # ⛔ AN UNREADABLE QUEUE IS NOT AN EMPTY QUEUE (invariant 1).
        return "UNMEASURED(read %s + %s: %s)" % (path, type(exc).__name__, exc)
    return data if isinstance(data, dict) else "UNMEASURED(read %s + not an object)" % path


def _write_reminders(path: str, data: Dict[str, Any]) -> Optional[str]:
    """Atomic: write a temp file in the same directory, then rename. A queue that is half-written when the
    server dies is a reminder that silently never fires."""
    tmp = path + ".tmp.%d" % os.getpid()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(tmp, "w") as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return "UNMEASURED(write %s + %s: %s)" % (path, type(exc).__name__, exc)
    return None


# ⛔ `cycle-record.sh` IS A LIBRARY (`cycle_record_write`, `cycle_verdict`), so it is SOURCED — with the
# script path passed as `$1` from argv, never interpolated into the script text. `bash -c` is acceptable
# here precisely because the text is a FIXED string this file owns; `box.exec` may never do this, because
# there the text would be a caller's.
CYCLE_VERDICT_SCRIPT = 'set -u; . "$1"; shift; cycle_verdict "$@"'
CYCLE_WRITE_SCRIPT = 'set -u; . "$1"; shift; cycle_record_write "$@"'


def _beat_checkpoint(mods: Modules, args: Dict[str, Any], read_only: bool) -> Tuple[bool, Dict[str, Any]]:
    action = str(args.get("action") or "")
    o = args.get("o") or os.environ.get("O") or os.path.join(
        os.environ.get("CELL_HOME") or os.environ.get("HOME") or os.path.expanduser("~"),
        "orchestrator")
    payload: Dict[str, Any] = {"measured_at": _now(), "action": action, "o": o}
    if action == "read":
        hours = int(args.get("hours") or 12)
        # ⛔ `report.sh` IS THE READ PATH (inventory M18): it reads ONLY durable artifacts and is declared
        # safe to run while the loop works. This tool must NOT add a third checkpoint reader.
        ran = run_module(mods, "report", [str(hours)], timeout=180.0, cap=200_000)
        payload["report"] = {"exit_code": ran.rc, "stdout": ran.stdout, "stderr": ran.stderr,
                             "truncated": ran.truncated, "source": "report.sh (loop-safe)",
                             "outcome": "READ" if ran.ok() else "UNMEASURED",
                             "unmeasured": None if ran.ok() else ran.unmeasured()}
        script = mods.path("cycle_record")
        if not script:
            payload["cycle_verdict"] = "UNMEASURED(resolve cycle-record.sh + %s)" % (
                mods.errors.get("cycle_record", "unknown"))
        else:
            vran = run(["bash", "-c", CYCLE_VERDICT_SCRIPT, "_", script, o], timeout=60.0)
            payload["cycle_verdict"] = {
                "exit_code": vran.rc, "verdict": vran.stdout.strip(),
                "outcome": {0: "HEALTHY", 1: "DEGRADED", 2: "NO-ANSWER"}.get(vran.rc, "UNMEASURED"),
                "source": "cycle-record.sh::cycle_verdict (no record / stale / unparseable is never "
                          "HEALTHY)",
                "unmeasured": None if vran.rc in (0, 1, 2) else vran.unmeasured(),
            }
        verdict_block = payload["cycle_verdict"]
        bad = (not ran.ok()) or (isinstance(verdict_block, dict)
                                 and verdict_block.get("outcome") in ("NO-ANSWER", "UNMEASURED"))
        return bool(bad), payload
    if action == "write":
        if read_only:
            payload["refused"] = "read-only"
            return True, payload
        state = args.get("state") or {}
        if not state:
            payload["refused"] = "state-required"
            return True, payload
        if not all(isinstance(k, str) and isinstance(v, str) for k, v in state.items()):
            payload["refused"] = "state-must-be-string-to-string"
            return True, payload
        script = mods.path("cycle_record")
        if not script:
            payload["unmeasured"] = "UNMEASURED(resolve cycle-record.sh + %s)" % (
                mods.errors.get("cycle_record", "unknown"))
            return True, payload
        pairs = ["%s=%s" % (k, v) for k, v in sorted(state.items())]
        wran = run(["bash", "-c", CYCLE_WRITE_SCRIPT, "_", script, o] + pairs, timeout=60.0)
        payload["write"] = {"exit_code": wran.rc, "argv": wran.argv[:6], "stdout": wran.stdout,
                            "stderr": wran.stderr,
                            "outcome": "WRITTEN" if wran.ok() else "UNMEASURED"}
        if not wran.ok():
            payload["unmeasured"] = wran.unmeasured()
        return (not wran.ok()), payload
    payload["refused"] = "unknown-action"
    payload["allowed"] = ["read", "write"]
    return True, payload


# ── JSON-RPC ──────────────────────────────────────────────────────────────────────────────────

def _result(msg_id: Any, result: Any) -> Dict[str, Any]:
    return {"jsonrpc": "2.0", "id": msg_id, "result": result}


def _error(msg_id: Any, code: int, message: str) -> Dict[str, Any]:
    return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}}


def _tool_result(payload: Any, is_error: bool) -> Dict[str, Any]:
    return {"content": [{"type": "text", "text": json.dumps(payload, indent=2, sort_keys=True,
                                                            default=str)}],
            "isError": bool(is_error)}


class Server:
    """Registry + Modules + the mutation mode. One object, so `handle()` stays a dispatcher."""

    def __init__(self, mods: Optional[Modules] = None, read_only: Optional[bool] = None) -> None:
        self.mods = mods or Modules()
        self.registry = Registry(self.mods)
        self.read_only = (os.environ.get("ORCH_MCP_READ_ONLY") == "1"
                          if read_only is None else bool(read_only))
        self.versions = instrument_versions(self.mods)

    INSTRUMENT_TOOLS = ("lane.list", "lane.show")

    def call(self, name: str, args: Dict[str, Any]) -> Tuple[bool, Any]:
        args = args or {}
        if name in self.INSTRUMENT_TOOLS:
            return (self.registry.list(args) if name == "lane.list"
                    else self.registry.show(args))
        if name == "lane.artifact":
            if not args.get("lane"):
                return True, {"error": "lane.artifact requires lane"}
            payload = _lane_artifact(self.mods, str(args["lane"]), args)
            words = payload.get("words") or {}
            files = payload.get("files")
            # ⛔ "none written" IS A VALUE (row 3's own rule) — ABSENT-EVERYWHERE is a clean answer. What
            # is NOT a clean answer is an unreadable lane (UNMEASURED), a caller bug (NO-LANE), or a pull
            # that failed: those three must not read as "this lane has no work".
            bad = words.get("outcome") != "ANSWERED"
            if isinstance(files, dict) and files.get("outcome") in ("UNMEASURED", "PULL-FAILED"):
                bad = True
            return bool(bad), payload
        if name == "fleet.census":
            payload = _census(self.mods, args)
            bad = any(isinstance(v, dict) and v.get("unmeasured") for v in payload["repos"].values())
            for block in payload["box"].values():
                # ⛔ `CANNOT-VERIFY` IS NOT A FIGURE. A census that reported it as one would be the
                # FALSE UNMEASURED defect on the tool the beat trusts most.
                if isinstance(block, dict) and block.get("outcome") in ("UNMEASURED", "CANNOT-VERIFY"):
                    bad = True
                if isinstance(block, str):
                    bad = True
            return bad, payload
        if name == "pr.queue":
            return _pr_queue(self.mods, args)
        if name == "claim.check":
            return _claim_check(self.mods, args)
        if name == "lane.dispatch":
            return _dispatch(self.mods, args, self.read_only)
        if name == "box.exec":
            return _box_exec(self.mods, args, self.read_only)
        if name == "pr.review_record":
            if args.get("pr") is None:
                return True, {"error": "pr.review_record requires pr"}
            return _review_record(self.mods, args)
        if name == "pr.closure_audit":
            if args.get("pr") is None or not args.get("repo"):
                return True, {"error": "pr.closure_audit requires pr and repo"}
            return _closure_audit(self.mods, args)
        if name == "fleet.reminder":
            return _reminder(self.mods, args, self.read_only)
        if name == "fleet.beat_checkpoint":
            return _beat_checkpoint(self.mods, args, self.read_only)
        return True, {"error": "no handler for %r" % name}


def handle(server: "Server", request: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """One request → one response, or None for a notification (which must never be answered)."""
    method = request.get("method")
    msg_id = request.get("id")
    params = request.get("params") or {}

    if msg_id is None:
        # ⛔ A JSON-RPC message with no `id` IS a notification, whatever its method — answering one with
        # `"id": null` desynchronises a strict client.
        return None
    if method == "initialize":
        return _result(msg_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {
                "name": SERVER_NAME, "version": SERVER_VERSION,
                "registry_path": server.registry.path,
                "registry_sha256": server.registry.sha256,
                "instrument_versions": server.versions,
                "instrument_sha256": instrument_sha(server.mods),
                "read_only": server.read_only,
                "surface": list(APPROVED_SURFACE),
                "tools": len(TOOLS),
            },
            "instructions": (
                "The orchestrator's typed tools. Lane STATE records are RUNNING | DONE | FAILED | EXPIRED; "
                "the liveness axis is alive | working | frozen | finished | no-verdict (+ dead on positive "
                "death evidence). Every figure carries measured_at, and a read that failed is "
                "UNMEASURED(<cmd> + <error>), never 0. box.exec takes an argv array and refuses anything "
                "not on its allowlist."),
        })
    if method == "ping":
        return _result(msg_id, {})
    if method == "tools/list":
        return _result(msg_id, {"tools": TOOLS})
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if name not in TOOL_NAMES:
            return _error(msg_id, -32602, "unknown tool %r; this server serves %s"
                          % (name, list(TOOL_NAMES)))
        try:
            is_err, payload = server.call(name, args)
        except Exception as exc:                       # noqa: BLE001 - a tool failure is a RESULT
            return _result(msg_id, _tool_result(
                {"error": "UNMEASURED(tool %s raised %s: %s)" % (name, type(exc).__name__, exc)},
                True))
        return _result(msg_id, _tool_result(payload, is_err))
    return _error(msg_id, -32601, "method not found: %r" % (method,))


def serve(stdin=None, stdout=None, mods: Optional[Modules] = None,
          read_only: Optional[bool] = None) -> int:
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    mods = mods or Modules()
    versions = instrument_versions(mods)
    if not versions["ok"]:
        # ⛔ INVARIANT 5: REFUSE TO START. This used to serve anyway with `UNMEASURED(resolve …)` on each
        # tool, which is the `no-op gate` polarity the invariant forbids — a server that answers with a
        # module set it cannot fingerprint is worse than one that says why it will not start.
        sys.stderr.write("[orchestrator-mcp] %s\n" % StartRefused(versions))
        for row in versions["modules"]:
            if not row["present"]:
                sys.stderr.write("[orchestrator-mcp]   MISSING %s (%s): %s\n"
                                 % (row["module"], row["wraps"], row["error"]))
        return 3
    server = Server(mods, read_only=read_only)
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError as exc:
            stdout.write(json.dumps(_error(None, -32700, "parse error: %s" % exc)) + "\n")
            stdout.flush()
            continue
        if not isinstance(request, dict):
            stdout.write(json.dumps(_error(None, -32600, "invalid request")) + "\n")
            stdout.flush()
            continue
        try:
            response = handle(server, request)
        except Exception:                              # noqa: BLE001 - never die mid-session
            response = _error(request.get("id"), -32603,
                              "internal error: %s" % traceback.format_exc(limit=3))
        if response is None:
            continue
        stdout.write(json.dumps(response) + "\n")
        stdout.flush()
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    read_only: Optional[bool] = None
    for a in argv:
        if a == "--read-only":
            read_only = True
        elif a == "--read-write":
            read_only = False
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            sys.stderr.write("orchestrator-mcp: unknown argument %r\n" % a)
            return 2
    return serve(read_only=read_only)


if __name__ == "__main__":
    sys.exit(main())
