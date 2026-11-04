#!/usr/bin/env python3
"""Tests for the orchestrator MCP server's first slice (`lane.list`, `lane.show`).

THE SURFACE IS PINNED BY A TEST, NOT BY A DOCSTRING (S3). The owner steer of 2026-11-04 is that a tool
surface grown without approval is a **contract change**, so the number of tools is an assertion: adding a
third tool to `server.py` reddens this suite. That is the only mechanism that makes "do not expand the
surface" enforceable rather than aspirational.

Each case names the failure it excludes:

    S1  `initialize` names the server AND the registry's sha256 — a stale deployed copy is
        DETECTABLE, not silent (inventory invariant 5, and #3016's stale-checkout incident)
    S2  a notification is NEVER answered (answering one desynchronises a strict client)
    S3  the surface is EXACTLY {lane.list, lane.show}
    S4  `lane.list` answers the five questions the fleet could not ask on 2026-11-04
    S5  `lane.show` on a stale heartbeat with no terminal record reports EXPIRED, and the reason cites
        the numbers it was derived from
    S6  an unknown id is `not_found` + `isError` — a LOOKUP outcome, never one of the four states
    S7  an unreadable registry is UNMEASURED, never `counts = {RUNNING: 0}`
    S8  unknown method / unknown tool are JSON-RPC errors, not silence
    S9  one malformed line does not kill the session — the next request is still answered
    S10 THE SERVER WRITES NOTHING: the registry's refs are byte-identical after a full session
    S11 the MCP's payload is the CLI's payload — ONE builder (`list_payload`), not a hand-copied twin
    S12 `lane.list` applies the filters it advertises (it used to ignore them entirely and answer a
        WIDER population, unlabelled)
    S13 `lane.show` refuses to assert NOT-FOUND from a PARTIAL (local-only) read
    S14 an illegal `state` filter is a tool ERROR, never a confident `counts = 0`
"""
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys

import pytest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SERVER = os.path.join(_HERE, "server.py")
_REGISTRY = os.path.abspath(os.path.join(_HERE, "..", "..", "scripts", "orchestrator-harness",
                                         "lane_registry.py"))


def _load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture()
def env(tmp_path, monkeypatch):
    """A hermetic fleet: bare `origin`, a registry repo whose origin is it, and an isolated state root."""
    origin = tmp_path / "origin.git"
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
    repo = tmp_path / "hub"
    repo.mkdir()
    subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(repo), "remote", "add", "origin", str(origin)], check=True)

    monkeypatch.setenv("LANE_REGISTRY_STATE", str(tmp_path / "state"))
    monkeypatch.setenv("LANE_REGISTRY_LOCAL", str(tmp_path / "state" / "lanes"))
    monkeypatch.setenv("LANE_REGISTRY_GIT", str(tmp_path / "state" / "work.git"))
    monkeypatch.setenv("LANE_REGISTRY_REPO", str(repo))
    monkeypatch.setenv("LANE_REGISTRY_PY", _REGISTRY)
    monkeypatch.delenv("AGENT_INFRA_PATH", raising=False)
    return _load(_REGISTRY, "lane_registry_for_mcp_tests"), origin, repo, tmp_path


def rpc(registry_mod, requests):
    """Drive the real `serve()` loop over a pipe. Returns the parsed responses, one per answer."""
    server = _load(_SERVER, "orchestrator_mcp_under_test")
    stdin = io.StringIO("\n".join(json.dumps(r) if not isinstance(r, str) else r for r in requests) + "\n")
    stdout = io.StringIO()
    server.serve(stdin, stdout)
    out = []
    for line in stdout.getvalue().splitlines():
        if line.strip():
            out.append(json.loads(line))
    return out


def call(registry_mod, name, arguments=None):
    resp = rpc(registry_mod, [{"jsonrpc": "2.0", "id": 7, "method": "tools/call",
                               "params": {"name": name, "arguments": arguments or {}}}])[0]
    assert "result" in resp, resp
    payload = json.loads(resp["result"]["content"][0]["text"])
    return resp["result"]["isError"], payload


def seed(registry_mod, origin, **kw):
    argv = ["start", "--remote", str(origin), "--kind", "lane", "--tag", str(kw.pop("tag", "1"))]
    for flag, value in kw.items():
        argv += ["--%s" % flag.replace("_", "-"), str(value)]
    import contextlib
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        rc = registry_mod.main(argv)
    assert rc == 0
    return registry_mod.new_lane_id.__self__ if False else _last_id(registry_mod)


def _last_id(mod):
    ok, _detail, records, _src = mod.read_registry(None, 20.0, allow_local_fallback=False)
    assert ok and records
    return sorted(records)[-1]


# ── S1 / S2 / S3 — the protocol and the pinned surface ────────────────────────────────────────

def test_S1_initialize_names_the_server_and_fingerprints_the_registry(env):
    mod, _origin, _repo, _tmp = env
    resp = rpc(mod, [{"jsonrpc": "2.0", "id": 1, "method": "initialize",
                      "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                                 "clientInfo": {"name": "t", "version": "0"}}}])[0]
    info = resp["result"]["serverInfo"]
    assert info["name"] == "orchestrator"
    assert resp["result"]["protocolVersion"]
    assert resp["result"]["capabilities"]["tools"]
    assert len(info["registry_sha256"]) == 64, info
    assert info["registry_path"] == _REGISTRY


def test_S2_a_notification_is_never_answered(env):
    mod = env[0]
    out = rpc(mod, [{"jsonrpc": "2.0", "method": "notifications/initialized"},
                    {"jsonrpc": "2.0", "id": 2, "method": "ping"}])
    assert len(out) == 1 and out[0]["id"] == 2, out


def test_S3_the_surface_is_EXACTLY_two_read_only_tools(env):
    """A third tool is a CONTRACT CHANGE and must be an owner decision — so it fails here first."""
    mod = env[0]
    tools = rpc(mod, [{"jsonrpc": "2.0", "id": 3, "method": "tools/list"}])[0]["result"]["tools"]
    names = [t["name"] for t in tools]
    assert names == ["lane.list", "lane.show"], names
    for tool in tools:
        assert tool["inputSchema"]["type"] == "object"
        # read-only: no mutating verb may appear in the surface
        for verb in ("start", "beat", "done", "fail", "write", "delete", "push"):
            assert verb not in tool["name"], tool["name"]


# ── S4 / S5 / S6 — the five questions ────────────────────────────────────────────────────────

def test_S4_lane_list_answers_the_five_questions(env):
    mod, origin, _repo, _tmp = env
    running = seed(mod, origin, tag="101")
    done = seed(mod, origin, tag="102")
    failed = seed(mod, origin, tag="103")
    import contextlib
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        assert mod.main(["done", "--remote", str(origin), "--lane-id", done, "--pr", "3419",
                         "--sha", "cafe1234"]) == 0
        assert mod.main(["fail", "--remote", str(origin), "--lane-id", failed,
                         "--reason", "brief-gate refused (80)"]) == 0

    is_err, payload = call(mod, "lane.list")
    assert is_err is False
    assert payload["counts"] == {"RUNNING": 1, "DONE": 1, "FAILED": 1, "EXPIRED": 0}
    assert [r["lane_id"] for r in payload["running"]] == [running]
    assert payload["oldest_unfinished"]["lane_id"] == running
    by_id = {r["lane_id"]: r for r in payload["lanes"]}
    assert {a["kind"]: a["value"] for a in by_id[done]["artifacts"]}["sha"] == "cafe1234"
    assert "brief-gate" in by_id[failed]["reason"]
    assert len(payload["registry_sha256"]) == 64
    assert payload["measured_at"] > 0


def test_S5_lane_show_reports_EXPIRED_with_the_numbers_it_derived_it_from(env):
    mod, origin, _repo, _tmp = env
    lane = seed(mod, origin, tag="999", budget="600")
    ok, _detail, records, _src = mod.read_registry(str(origin), 20.0, allow_local_fallback=False)
    assert ok
    rec = dict(records[lane])
    rec.pop("_ref", None)
    rec.pop("_sha", None)
    rec["heartbeat_at"] = int(rec["heartbeat_at"]) - 3600
    rec["lease_until"] = rec["heartbeat_at"] + int(rec["budget_s"])
    assert mod._push(rec, str(origin), 20.0)[0]

    is_err, payload = call(mod, "lane.show", {"lane_id": lane})
    assert payload["state"] == "EXPIRED", payload
    assert "lease-lapsed" in payload["state_reason"]
    assert str(rec["lease_until"]) in payload["state_reason"]
    assert is_err is False, "an EXPIRED lane is a VERDICT, not a tool error"


def test_S6_an_unknown_lane_is_not_found_and_never_a_state(env):
    mod = env[0]
    is_err, payload = call(mod, "lane.show", {"lane_id": "does-not-exist"})
    assert is_err is True
    assert payload["not_found"] == "does-not-exist"
    for state in ("RUNNING", "DONE", "FAILED", "EXPIRED"):
        assert state not in json.dumps(payload)


def test_S6b_lane_show_without_an_id_is_a_tool_error(env):
    is_err, payload = call(env[0], "lane.show", {})
    assert is_err is True and "lane_id" in payload["error"]


# ── S7 / S8 / S9 — abstentions and protocol robustness ───────────────────────────────────────

def test_S7_an_unreadable_shared_registry_is_never_a_complete_answer(env):
    """Two distinguishable failures, and NEITHER may read as "the fleet is empty".

    (a) the shared store is unreachable and THIS BOX has records  -> records returned, `local-only`,
        `isError` — a partial answer that must not be read as the fleet.
    (b) the shared store is unreachable and there are no local records either -> UNMEASURED, no counts.
    """
    mod, origin, _repo, _tmp = env
    seed(mod, origin)
    import shutil
    shutil.rmtree(origin)
    is_err, payload = call(mod, "lane.list")
    assert is_err is True, "a local-only answer is not a complete fleet answer"
    assert payload["coverage"] == "local-only", payload
    assert payload["counts"]["RUNNING"] == 1, "the records ARE returned — labelled, not withheld"

    shutil.rmtree(os.environ["LANE_REGISTRY_LOCAL"])          # …and now (b)
    is_err, payload = call(mod, "lane.list")
    assert is_err is True
    assert "UNMEASURED(" in json.dumps(payload)
    assert "counts" not in payload, payload


def test_S8_unknown_method_and_unknown_tool_are_errors_not_silence(env):
    mod = env[0]
    out = rpc(mod, [{"jsonrpc": "2.0", "id": 1, "method": "no/such"},
                    {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                     "params": {"name": "lane.dispatch", "arguments": {}}}])
    assert out[0]["error"]["code"] == -32601
    assert out[1]["error"]["code"] == -32602


def test_S9_a_malformed_line_does_not_kill_the_session(env):
    mod = env[0]
    out = rpc(mod, ["{ this is not json",
                    {"jsonrpc": "2.0", "id": 5, "method": "ping"}])
    assert out[0]["error"]["code"] == -32700
    assert out[1]["id"] == 5 and "result" in out[1]


# ── S10 — it is a READER ─────────────────────────────────────────────────────────────────────

def test_S10_a_full_session_writes_nothing_to_the_registry(env):
    mod, origin, _repo, _tmp = env
    lane = seed(mod, origin, tag="501")
    before = subprocess.run(["git", "ls-remote", str(origin)], capture_output=True, text=True,
                            check=True).stdout
    rpc(mod, [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
              {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
              {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
               "params": {"name": "lane.list", "arguments": {}}},
              {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
               "params": {"name": "lane.show", "arguments": {"lane_id": lane}}}])
    after = subprocess.run(["git", "ls-remote", str(origin)], capture_output=True, text=True,
                           check=True).stdout
    assert before == after, "the MCP surface is READ-ONLY: only the launcher that owns a lane writes"


def test_S11_the_mcp_answers_identically_to_the_cli(env):
    """One derivation, two surfaces. A different answer from the MCP is the duplication #3382 forbids."""
    mod, origin, _repo, _tmp = env
    seed(mod, origin, tag="601")
    import contextlib
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        assert mod.main(["list", "--remote", str(origin), "--json"]) == 0
    cli = json.loads(out.getvalue())
    _is_err, mcp = call(mod, "lane.list")
    # ⛔ THE WHOLE OBJECT, NOT THREE KEYS. Comparing `counts`/`lanes`/`oldest_unfinished` is what let a
    # hand-copied payload builder in this file drift from `cmd_list` while its docstring promised an
    # identical shape. Both surfaces now call `list_payload`; this asserts it, key by key.
    for key in ("registry_path", "registry_sha256"):
        mcp.pop(key, None)
    cli.pop("measured_at", None)
    mcp.pop("measured_at", None)
    assert cli == mcp, {k: (cli.get(k), mcp.get(k)) for k in set(cli) | set(mcp)
                        if cli.get(k) != mcp.get(k)}


def test_S12_lane_list_applies_the_filters_it_advertises(env):
    """`lane.list {state:"FAILED"}` used to answer a WIDER population than asked, with no marker.

    The MCP calls `collect`, which applied no filters (they lived in `cmd_list` only), so a caller asking
    "what failed" got the DONE and the RUNNING lane too — a filter-shaped false answer, and a divergence
    from the CLI with the same arguments. One read path, one answer, and the filter is LABELLED.
    """
    mod, origin, _repo, _tmp = env
    done = seed(mod, origin, tag="701")
    running = seed(mod, origin, tag="702")
    assert mod.main(["done", "--lane-id", done, "--pr", "8", "--remote", str(origin), "--quiet"]) == 0
    _is_err, payload = call(mod, "lane.list", {"state": "DONE"})
    assert [r["lane_id"] for r in payload["lanes"]] == [done], payload["lanes"]
    assert payload["counts"]["RUNNING"] == 0 and payload["counts"]["DONE"] == 1
    assert payload["filters"] == {"state": "DONE"}
    assert payload["oldest_unfinished"] is None
    _is_err, everything = call(mod, "lane.list", {})
    assert {r["lane_id"] for r in everything["lanes"]} == {done, running}
    assert everything["filters"] == {}


def test_S13_lane_show_refuses_to_assert_NOT_FOUND_from_a_partial_read(env, tmp_path):
    """A local-only read cannot see peer lanes, so an absent id is UNMEASURED, not "never existed"."""
    mod, origin, _repo, _tmp = env
    seed(mod, origin, tag="801")
    shutil.rmtree(origin)                                  # the shared store is gone; local copy remains
    is_err, payload = call(mod, "lane.show", {"lane_id": "nope.never.existed"})
    assert is_err, payload
    assert "not_found" not in payload and "UNMEASURED" in payload["error"], payload


def test_S14_an_illegal_filter_is_a_tool_error_not_a_confident_zero(env):
    """`lane.list {state:"BOGUS"}` answered `counts.RUNNING == 0` with `isError: false`.

    The CLI refused the same argument (argparse `choices`, exit 2), so the MCP answered a question it did
    not understand with a definite "nothing is running" — the false-clean #3382 invariant 1 forbids, on
    the surface the owner is meant to use.
    """
    mod, origin, _repo, _tmp = env
    seed(mod, origin, tag="901")
    is_err, payload = call(mod, "lane.list", {"state": "BOGUS"})
    assert is_err, payload
    assert "invalid argument" in payload["error"], payload
    assert "counts" not in payload, payload
    # …and the valid argument still answers normally.
    is_err, payload = call(mod, "lane.list", {"state": "RUNNING"})
    assert not is_err and payload["counts"]["RUNNING"] == 1, payload


def test_S15_a_local_only_show_is_an_error_too(env):
    """`lane.list` raised `isError` on `coverage != shared`; `lane.show` returned `isError:false` for a
    record read from this box's own witness — two answers to "is this complete?" on one surface."""
    mod, origin, _repo, _tmp = env
    lane = seed(mod, origin, tag="1001")
    shutil.rmtree(origin)                       # shared store gone; the local copy still answers
    is_err, payload = call(mod, "lane.show", {"lane_id": lane})
    assert payload.get("lane_id") == lane, payload
    assert is_err, payload
    assert payload["coverage"] == "local-only", payload
