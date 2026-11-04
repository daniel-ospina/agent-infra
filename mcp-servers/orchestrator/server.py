#!/usr/bin/env python3
"""Orchestrator MCP server — slice 1: the lane STATE primitive, read-only.

TWO TOOLS, AND NO MORE WITHOUT OWNER APPROVAL
---------------------------------------------
    lane.list   → every lane with the four-state reading, plus the five answers
    lane.show   → one lane, or `NOT-FOUND` (a lookup outcome, never a state)

That is the whole surface. `agent-infra#3382`'s Phase 1 inventory
(`docs/ops/orchestrator-mcp-inventory.md`) names 14 tools; growing this server past this slice is a
**contract change, not an implementation detail**, and the owner steer of 2026-11-04 is explicit about the
order: the state primitive first, because *"an orchestration MCP whose tools cannot answer 'did it finish'
is a typed façade over blindness"*.

WHY A SEPARATE PROCESS AND NOT A pi EXTENSION
---------------------------------------------
Already decided in the inventory (§8.1), and this server is the first thing it decides: the requirement is
"reaches the same answer on a fresh box with zero local scripts", and an in-process extension is pi-only
and has no start gate to refuse at. See that section rather than re-arguing it here.

READ-ONLY BY DEFAULT — ENFORCED, NOT DOCUMENTED
-----------------------------------------------
The inventory's open question 5 recommends "read-only unless a mutation flag is set" with `box_exec` gated
hardest. This slice takes the strictest reading available: **both tools are reads, the server never writes
a record, and there is no flag that makes it.** `start`/`beat`/`done`/`fail` exist only as the CLI that the
LAUNCHER calls (`spawn-gate.sh::run_agent`), so the only writer is the process that owns the lane. A tool
surface that can also mutate would be a second writer with a different failure mode.

The one write this process does perform is `git ls-remote` + a `fetch` into a temp bare repo — a read of
the repository, into a directory under the system temp root that is removed in a `finally`. It never
touches the caller's repository, refs, or worktree.

TRANSPORT
---------
MCP stdio: newline-delimited JSON-RPC 2.0 on stdin/stdout, nothing else on stdout (logs go to stderr).
Zero third-party packages — `node_modules`/`pip install` are not preconditions for the fleet to be able to
say whether its lanes finished, and a server that cannot start on a bare cell is an outage wearing a
tool's name.

    initialize · notifications/initialized · tools/list · tools/call · ping
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import traceback
from typing import Any, Dict, List, Optional, Tuple

SERVER_NAME = "orchestrator"
SERVER_VERSION = "0.1.0"
PROTOCOL_VERSION = "2024-11-05"

TOOL_NAMES = ("lane.list", "lane.show")

TOOLS: List[Dict[str, Any]] = [
    {
        "name": "lane.list",
        "description": (
            "Every lane the fleet has a STATE RECORD for, with the four-state reading "
            "RUNNING | DONE | FAILED | EXPIRED. Answers, from the records alone: which lanes are "
            "running; which finished and with what artifacts/shas; which failed and why; which "
            "expired (no heartbeat past the stated budget, no terminal record); and the oldest "
            "unfinished lane. `EXPIRED` is DERIVED from the record's lease — never written. "
            "An unreadable registry returns UNMEASURED(<cmd> + <error>), NEVER an empty list: "
            "unknown is not zero. Read-only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "state": {"type": "string", "enum": ["RUNNING", "DONE", "FAILED", "EXPIRED"],
                          "description": "only lanes in this state"},
                "host": {"type": "string", "description": "only lanes recorded on this host"},
                "repo": {"type": "string", "description": "only lanes for this owner/name"},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "lane.show",
        "description": (
            "One lane's state record: state, state_reason (which cites the numbers the state was "
            "derived from), host/pid, branch/worktree, started_at/heartbeat_at/lease_until/budget_s, "
            "and the artifacts a DONE record is required to name. Returns NOT-FOUND — exit-style — "
            "for an id with no record, which is a lookup outcome and NOT one of the four states. "
            "Read-only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"lane_id": {"type": "string", "description": "the lane id"}},
            "required": ["lane_id"],
            "additionalProperties": False,
        },
    },
]


# ── the registry, resolved once and FINGERPRINTED ──────────────────────────────────────────────

def _candidate_paths() -> List[str]:
    here = os.path.dirname(os.path.abspath(__file__))
    home = os.environ.get("CELL_HOME") or os.environ.get("HOME") or os.path.expanduser("~")
    out = [
        os.environ.get("LANE_REGISTRY_PY", ""),
        os.path.join(os.environ.get("AGENT_INFRA_PATH", ""), "scripts", "orchestrator-harness",
                     "lane_registry.py"),
        os.path.abspath(os.path.join(here, "..", "..", "scripts", "orchestrator-harness",
                                     "lane_registry.py")),
        os.path.join(os.environ.get("O", os.path.join(home, "orchestrator")), "lane_registry.py"),
        os.path.join(home, ".pi", "agent", "scripts", "lane_registry.py"),
    ]
    return [p for p in out if p]


class Registry:
    """The wrapped module + its sha256.

    ⛔ THE FINGERPRINT IS PART OF THE ANSWER, NOT DEBUG OUTPUT (inventory invariant 5 / #3016). Measured:
    a checkout 151 commits behind its pin ran a `scripts/` tree older than the box claimed, and every
    instrument on that box agreed with the stale copy. A version nobody can read is a stale deployed copy
    that is DETECTABLE, not silent — so `registry_sha256` rides on every payload and on `initialize`.
    """

    def __init__(self) -> None:
        self.path: Optional[str] = None
        self.sha256: Optional[str] = None
        self.module = None
        self.error: Optional[str] = None
        for candidate in _candidate_paths():
            if not (candidate and os.path.isfile(candidate)):
                continue
            try:
                with open(candidate, "rb") as fh:
                    self.sha256 = hashlib.sha256(fh.read()).hexdigest()
                spec = importlib.util.spec_from_file_location("lane_registry_served", candidate)
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
            except Exception as exc:                        # noqa: BLE001 - a bad copy is an abstention
                self.error = "%s: %s: %s" % (candidate, type(exc).__name__, exc)
                continue
            self.path, self.module = candidate, mod
            return
        if self.error is None:
            self.error = "lane_registry.py not found in: %s" % ", ".join(_candidate_paths())

    def unmeasured(self) -> str:
        # ⛔ THE CONVENTION FROM #3382: a figure that could not be read is `UNMEASURED(<cmd> + <error>)`.
        return "UNMEASURED(resolve lane_registry.py + %s)" % (self.error or "unknown failure")

    def list(self, args: Dict[str, Any]) -> Tuple[bool, Any]:
        if self.module is None:
            return True, {"error": self.unmeasured(), "registry_sha256": None}
        # ⛔ AN ILLEGAL FILTER IS REFUSED HERE TOO, because this surface has no argparse `choices` — so
        # `state:"BOGUS"` (or `"RUNNING "` with a stray space) used to answer a DEFINITE `RUNNING=0` with
        # `isError: false`, while the CLI exited 2 for the same argument. A tool that answers a confident
        # zero to a question it did not understand is the false clean #3382 invariant 1 forbids.
        want_state = args.get("state")
        if want_state and str(want_state).strip().upper() not in self.module.STATES:
            return True, {"error": "invalid argument: state %r is not one of %s"
                                   % (want_state, list(self.module.STATES)),
                          "registry_sha256": self.sha256}
        ok, detail, rows, code, applied, extra = self.module.collect(_ns(remote=None,
                                                                       state=want_state,
                                                                       host=args.get("host"),
                                                                       repo=args.get("repo"),
                                                                       timeout=20.0))
        if not ok:
            # ⛔ THE REASON MUST BE THE *READ'S*, NOT THE MODULE'S. This used to report
            # "UNMEASURED(resolve lane_registry.py …)" for an unreachable registry, sending an operator
            # to redeploy scripts when the remote was simply down.
            head = "invalid argument" if code == self.module.USAGE else "UNMEASURED"
            return True, {"error": "%s(%s)" % (head, detail),
                          "unmeasured": "UNMEASURED(%s)" % detail,
                          "registry_path": self.path, "registry_sha256": self.sha256}
        payload = self.module.list_payload(detail, rows, applied, extra)
        payload["registry_path"] = self.path
        payload["registry_sha256"] = self.sha256
        # ⛔ `local-only` IS AN ERROR ON THIS SURFACE, even though records were read. The question this
        # tool exists to answer is about the FLEET; a fallback to this box's own copies answers a
        # narrower question, and returning it as success would be the FALSE-CLEAN in tool-result
        # clothing. The records are still returned — a partial answer labelled is useful; labelled as
        # complete it is not.
        return payload.get("coverage") != "shared", payload

    def show(self, args: Dict[str, Any]) -> Tuple[bool, Any]:
        lane_id = (args or {}).get("lane_id")
        if not lane_id:
            return True, {"error": "lane.show requires lane_id"}
        if self.module is None:
            return True, {"error": self.unmeasured(), "registry_sha256": None}
        ok, detail, rows, code, _applied, extra = self.module.collect(_ns(remote=None, state=None,
                                                                         host=None, repo=None,
                                                                         timeout=20.0))
        if not ok:
            return True, {"error": "UNMEASURED(%s)" % detail,
                          "unmeasured": "UNMEASURED(%s)" % detail,
                          "registry_path": self.path, "registry_sha256": self.sha256}
        for row in rows:
            if row["lane_id"] == lane_id:
                row = dict(row)
                row["measured_at"] = _now()
                row["coverage"] = self.module.coverage(str(extra.get("source") or "none"))
                row["source"] = detail
                row["registry_path"] = self.path
                row["registry_sha256"] = self.sha256
                # ⛔ A LOCAL-ONLY READ IS AN ERROR HERE TOO. `lane.list` raised `isError` on `coverage !=
                # shared` while `show` returned `isError:false` for a record read from this box's own
                # witness — two answers to "is this answer complete?" on the same surface, and docs §6
                # says local-only raises. The not-found branch below always did it; the found branch did not.
                return self.module.coverage(str(extra.get("source") or "none")) != "shared", row
        # ⛔ NOT-FOUND FROM A PARTIAL READ IS NOT A VERDICT — an absent id may belong to a peer this box
        # cannot see. Say UNMEASURED instead of inventing an absence.
        if self.module.coverage(str(extra.get("source") or "none")) != "shared":
            return True, {"error": "UNMEASURED(%s) — NOT-FOUND cannot be asserted from a read that did "
                                   "not reach the shared registry" % detail,
                          "registry_sha256": self.sha256}
        return True, {"not_found": lane_id,
                      "note": "NOT-FOUND is a lookup outcome, not one of the four states",
                      "coverage": self.module.coverage(str(extra.get("source") or "none")),
                      "registry_sha256": self.sha256}


def _now() -> int:
    import time
    return int(time.time())


def _ns(remote, state, host, repo, timeout):
    """The argparse-shaped namespace `collect()` expects — one adapter, so the MCP surface reuses the
    CLI's own derivation rather than re-implementing the four-state rule (a second implementation is the
    defect this whole issue exists to prevent)."""
    import argparse
    return argparse.Namespace(remote=remote, timeout=timeout, quiet=True, json=True,
                              state=state, host=host, repo=repo)


# ── JSON-RPC ──────────────────────────────────────────────────────────────────────────────────

def _result(msg_id: Any, result: Any) -> Dict[str, Any]:
    return {"jsonrpc": "2.0", "id": msg_id, "result": result}


def _error(msg_id: Any, code: int, message: str) -> Dict[str, Any]:
    return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}}


def _tool_result(payload: Any, is_error: bool) -> Dict[str, Any]:
    return {"content": [{"type": "text", "text": json.dumps(payload, indent=2, sort_keys=True)}],
            "isError": bool(is_error)}


def handle(registry: Registry, request: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """One request → one response, or None for a notification (which must never be answered)."""
    method = request.get("method")
    msg_id = request.get("id")
    params = request.get("params") or {}

    if msg_id is None:
        # ⛔ A JSON-RPC message with no `id` IS a notification, whatever its method — answering one with
        # `"id": null` desynchronises a strict client. `initialize` is the one exception a client may send
        # WITHOUT an id while still expecting a reply only if it sent one.
        return None
    if method == "initialize":
        return _result(msg_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION,
                           "registry_path": registry.path,
                           "registry_sha256": registry.sha256},
            "instructions": ("Lane STATE records. Four states: RUNNING | DONE | FAILED | EXPIRED. "
                             "Read-only: start/beat/done/fail are written by the launcher that owns "
                             "the lane, never by this server."),
        })
    if method == "ping":
        return _result(msg_id, {})
    if method == "tools/list":
        return _result(msg_id, {"tools": TOOLS})
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if name not in TOOL_NAMES:
            return _error(msg_id, -32602, "unknown tool %r; this slice serves %s"
                          % (name, list(TOOL_NAMES)))
        try:
            is_err, payload = (registry.list(args) if name == "lane.list"
                               else registry.show(args))
        except Exception as exc:                       # noqa: BLE001 - a tool failure is a RESULT
            return _result(msg_id, _tool_result(
                {"error": "UNMEASURED(tool %s raised %s: %s)" % (name, type(exc).__name__, exc)},
                True))
        return _result(msg_id, _tool_result(payload, is_err))
    return _error(msg_id, -32601, "method not found: %r" % (method,))


def serve(stdin=None, stdout=None) -> int:
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    registry = Registry()
    if registry.module is None:
        sys.stderr.write("[orchestrator-mcp] %s\n" % registry.unmeasured())
        # ⛔ IT STILL SERVES. A server that refuses to start cannot say WHY, and `initialize` is the one
        # message a client always sends — so the abstention travels as a tool result instead of as a dead
        # process. (A start gate that refuses is inventory invariant 5's shape for a MISSING module; here
        # the module resolves or the answer is UNMEASURED, which is strictly more informative.)
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
            response = handle(registry, request)
        except Exception:                              # noqa: BLE001 - never die mid-session
            response = _error(request.get("id"), -32603,
                              "internal error: %s" % traceback.format_exc(limit=3))
        if response is None:
            continue
        stdout.write(json.dumps(response) + "\n")
        stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(serve())
