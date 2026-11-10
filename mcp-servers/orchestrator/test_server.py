#!/usr/bin/env python3
"""Tests for the orchestrator MCP server (#3382): the 11 tools / 12 names, and invariants 1-6.

THE SURFACE IS PINNED BY A TEST, NOT BY A DOCSTRING (S3). The owner steer of 2026-11-04 is that a tool
surface grown without approval is a **contract change**, so the surface is an assertion: a thirteenth name,
or a tool that omits one of the four MCP annotations, reddens this suite. That is the only mechanism that
makes "do not expand the surface" enforceable rather than aspirational.

EVERY TEST NAMES THE FIXTURE IT REPRODUCES, and the invariant fixtures are the six MEASURED failures of
2026-11-03 (issue #3382), not invented cases:

    I1  UNKNOWN != ZERO — three ways to fail, and the reason INSIDE `UNMEASURED(...)` must name the right
        cause. `UNMEASURED` with the wrong cause is still a lie (FALSE UNMEASURED: `gh` succeeded, the
        payload did not parse, and the caller reported 'gh failed').
    I2  an `open` issue is NEVER merged/closed/done — a `#N` MENTION is not a closure (FALSE MERGED: 7 PRs
        printed as merged, all seven `open`), a stale read is not a closure, and an unreadable issue is
        NOT "closed".
    I3  a finished lane is NEVER `dead`, and no verdict is `no-verdict` with its reason — the three
        measured finished shapes (FALSE DEATH x3: 27 turns/2 PRs, 7 files + 3 dispatches, a 383 B
        artifact + a merged PR).
    I4  every number carries its measurement time and a CORRECTLY-COMPUTED age — the future stamp is
        clamped, the unparseable one is not `0m ago` (STALE CLOCK: `as of 14:16, 0m ago` for a
        five-hour-old stamp).
    I5  `instrument_versions()` lists each wrapped module's sha256 and the server REFUSES TO START when
        one is missing — the exit-2/unreadable case is the one a naive implementation passes.
    I6  MUTATION, RED FIRST — the pre-fix line for STALE CLOCK is in git (`b54b117fc`), so the harness
        checks that blob out, requires the fixture to FAIL against it, then requires HEAD to pass.

Each case names the failure it excludes:

    S1  `initialize` names the server AND the registry's sha256 — a stale deployed copy is
        DETECTABLE, not silent (inventory invariant 5, and #3016's stale-checkout incident)
    S2  a notification is NEVER answered (answering one desynchronises a strict client)
    S3  the surface is EXACTLY the approved set (11 tools / 12 names), and EVERY tool declares ALL FOUR
        MCP annotations — an unannotated tool is treated as destructive and open-world by default
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

# The surface pin lives in `server.APPROVED_SURFACE`; it is restated here ON PURPOSE so that changing the
# server without changing this file is impossible (a pin read from the artefact it pins pins nothing).
APPROVED = [
    "lane.list", "lane.show", "lane.artifact", "fleet.census", "pr.queue", "claim.check",
    "lane.dispatch", "box.exec", "pr.review_record", "pr.closure_audit", "fleet.reminder",
    "fleet.beat_checkpoint",
]
READ_ONLY_NAMES = ["lane.list", "lane.show", "lane.artifact", "fleet.census", "pr.queue", "claim.check",
                   "pr.review_record", "pr.closure_audit"]
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


def rpc(registry_mod, requests, mod=None):
    """Drive the real `serve()` loop over a pipe. Returns the parsed responses, one per answer.

    `mod` lets a test drive the SAME module object it monkeypatched — a fresh `_load` would carry the
    patch on a module nobody serves.
    """
    server = mod or _load(_SERVER, "orchestrator_mcp_under_test")
    stdin = io.StringIO("\n".join(json.dumps(r) if not isinstance(r, str) else r for r in requests) + "\n")
    stdout = io.StringIO()
    server.serve(stdin, stdout)
    out = []
    for line in stdout.getvalue().splitlines():
        if line.strip():
            out.append(json.loads(line))
    return out


def call(registry_mod, name, arguments=None, mod=None):
    resp = rpc(registry_mod, [{"jsonrpc": "2.0", "id": 7, "method": "tools/call",
                               "params": {"name": name, "arguments": arguments or {}}}], mod=mod)[0]
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


def test_S3_the_surface_is_EXACTLY_the_approved_set_with_all_four_annotations(env):
    """A thirteenth name, or a tool without all four annotations, is a CONTRACT CHANGE — it fails here.

    The MCP spec's defaults are pessimistic: an unannotated tool is treated as destructive,
    non-idempotent and open-world. So "omitted" is not neutral, it is the worst available reading — which
    is why the assertion is on the EXACT KEY SET and not on "some annotations exist".
    """
    mod = _load(_SERVER, "orchestrator_mcp_under_test")
    tools = rpc(env[0], [{"jsonrpc": "2.0", "id": 3, "method": "tools/list"}], mod=mod)[0]["result"]["tools"]
    names = [t["name"] for t in tools]
    assert names == APPROVED, names
    assert list(mod.APPROVED_SURFACE) == APPROVED
    assert list(mod.TOOL_NAMES) == APPROVED
    for tool in tools:
        assert tool["inputSchema"]["type"] == "object"
        annotations = tool.get("annotations")
        assert set(annotations) == {"readOnlyHint", "destructiveHint", "idempotentHint",
                                    "openWorldHint"}, (tool["name"], annotations)
        for key, value in annotations.items():
            assert isinstance(value, bool), (tool["name"], key, value)
        # a read-only tool must not name a mutating verb
        if tool["name"] in READ_ONLY_NAMES:
            assert annotations["readOnlyHint"] is True, tool["name"]
            # ⛔ AND IT IS STILL OPEN-WORLD: "read-only" is about WRITES, "open-world" is about
            # reaching OUTSIDE. Every read row here fetches from a git remote, `gh`, or a cell, so
            # `False` was the permissive half of the pair — and pinning `False` made a FUTURE CORRECT
            # value red. Pin the true one.
            assert annotations["openWorldHint"] is True, tool["name"]
            for verb in ("start", "beat", "done", "fail", "write", "delete", "push", "exec"):
                assert verb not in tool["name"], tool["name"]
    by_name = {t["name"]: t["annotations"] for t in tools}
    # ⛔ THE SPEC'S OWN EXAMPLE for `openWorldHint: true` is "a shell command" — `box.exec` IS one, so it
    # must be the most conservative row on the surface, not one of the read rows.
    assert by_name["box.exec"]["destructiveHint"] is True
    assert by_name["box.exec"]["openWorldHint"] is True
    assert by_name["box.exec"]["readOnlyHint"] is False
    assert by_name["lane.dispatch"]["openWorldHint"] is True
    assert by_name["lane.dispatch"]["destructiveHint"] is False       # additive: it launches, it kills none
    assert by_name["fleet.reminder"]["readOnlyHint"] is False
    assert by_name["fleet.beat_checkpoint"]["readOnlyHint"] is False


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
                     "params": {"name": "box.spawn", "arguments": {}}}])
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
    for key in ("registry_path", "registry_sha256", "instrument_sha256", "liveness",
                "liveness_requested", "liveness_source"):
        mcp.pop(key, None)
    cli.pop("measured_at", None)
    mcp.pop("measured_at", None)
    # ⛔ THE ONLY FIELDS NORMALISED ARE THE ONES THAT ARE A FUNCTION OF *WHEN* THE READ HAPPENED. Both
    # surfaces answer from the same builder; `age_s` is computed at read time, so two reads a second
    # apart legitimately disagree there and nowhere else. Normalising anything else would weaken the
    # "one builder" assertion this test exists for.
    for blob in (cli, mcp):
        for row in blob.get("lanes", []):
            row.pop("age_s", None)
            row.pop("heartbeat_age_s", None)
        for key in ("running", "expired"):
            for row in blob.get(key, []):
                row.pop("age_s", None)
        if blob.get("oldest_unfinished"):
            blob["oldest_unfinished"].pop("age_s", None)
    diff = {}
    for key in set(cli) | set(mcp):
        if cli.get(key) == mcp.get(key):
            continue
        if key == "lanes":
            # name the FIELD, not the blob: a dict-vs-dict failure is unreadable and this assertion is
            # the one that catches a payload builder drifting.
            fields = set()
            for a, b in zip(cli.get("lanes") or [], mcp.get("lanes") or []):
                fields |= {f for f in set(a) | set(b) if a.get(f) != b.get(f)}
            diff[key] = sorted(fields)
        else:
            diff[key] = (cli.get(key), mcp.get(key))
    assert not diff, diff


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


# ── the harness for the ten new tools: every wrapped module has an ENV SEAM ───────────────────
#
# ⛔ A TEST THAT REACHES THE LIVE FLEET IS NOT A TEST. Each stub below is a script the wrapped module's
# own runner executes through the seam `WRAPPED` declares, so what is exercised is the REAL
# `run_module` → parse → map path, with only the leaf replaced.

def server_mod(monkeypatch, **env):
    mod = _load(_SERVER, "orchestrator_mcp_under_test")
    for key, value in env.items():
        monkeypatch.setenv(key, str(value))
    monkeypatch.setenv("ORCH_MCP_STATE_DIR", os.environ.get("ORCH_MCP_STATE_DIR", ""))
    return mod


def stub(tmp_path, name, body, code=0):
    """Write an executable stub and return its path. `body` is the script; `code` its exit status."""
    path = tmp_path / name
    path.write_text("#!%s\n%s\n" % (sys.executable, body) + (
        "import sys\nsys.exit(%d)\n" % code if code else ""))
    os.chmod(path, 0o755)
    return str(path)


def stub_json(tmp_path, name, payload, code=0):
    return stub(tmp_path, name, "import json\nprint(json.dumps(%r))" % (payload,), code=code)


def one(mod, name, arguments):
    return call(None, name, arguments, mod=mod)


# ── I1 — UNKNOWN != ZERO, and the reason must name the RIGHT cause ───────────────────────────

def test_I1_a_failed_read_is_unmeasured_and_the_reason_names_the_cause(tmp_path, monkeypatch):
    """The FALSE UNMEASURED fixture: `gh` SUCCEEDED, the payload did not parse, and the caller reported
    'gh failed'. Three ways to fail, three DIFFERENT reason strings — asserting only that `UNMEASURED`
    appeared passes on the broken version, because the broken version also said `UNMEASURED`.
    """
    mod = server_mod(monkeypatch)

    # (a) the command ran and FAILED — the reason is its rc and its own stderr
    failed = stub(tmp_path, "wip_rc1.py", "import sys\nsys.stderr.write('boom: no lane table\\n')",
                  code=1)
    monkeypatch.setenv("ORCH_MCP_LANE_WIP", failed)
    is_err, payload = one(mod, "lane.artifact", {"lane": "X"})
    reason = payload["words"]["unmeasured"]
    assert is_err and "UNMEASURED(" in reason
    assert "rc=1" in reason and "boom" in reason, reason
    assert "not JSON" not in reason, "a FAILED command must not be described as a PARSE failure"

    # (b) the command SUCCEEDED and the payload did not parse — naming `rc` here is the measured lie
    bad = stub(tmp_path, "wip_notjson.py", "print('this is prose, not a payload')")
    monkeypatch.setenv("ORCH_MCP_LANE_WIP", bad)
    is_err, payload = one(mod, "lane.artifact", {"lane": "X"})
    reason = payload["words"]["unmeasured"]
    assert is_err and "not JSON" in reason, reason
    assert "rc=0" in reason and "RAN" in reason, reason
    # the only mention of failure is the one DENYING it: the reason must not read as a command failure
    assert "rc=0" in reason and "-> rc=1" not in reason and "failed:" not in reason, reason

    # (c) the command never finished — a TIMEOUT, which used to be a traceback out of the section
    ran = mod.run([sys.executable, "-c", "import time; time.sleep(5)"], timeout=0.4)
    assert ran.timed_out and ran.rc is None
    assert "timeout after 0.4s" in ran.reason(), ran.reason()
    assert "timeout" in ran.unmeasured() and sys.executable in ran.cmd, (
        ran.unmeasured(), ran.cmd)
    assert "UNMEASURED(" in ran.unmeasured()

    # (d) …and none of the three is ever a ZERO
    for reason in (payload["words"]["unmeasured"], ran.unmeasured()):
        assert not reason.endswith("0)")


def test_I1b_a_missing_module_is_a_named_abstention_not_an_empty_answer(tmp_path, monkeypatch):
    mod = server_mod(monkeypatch, ORCH_MCP_LANE_WIP=str(tmp_path / "does-not-exist.py"))
    # The resolver falls back to the repo copy, so force the seam to be the ONLY candidate FOR THIS ONE
    # MODULE — making it the only candidate for every module would (correctly) refuse to start.
    real = mod._candidate_paths
    monkeypatch.setattr(mod, "_candidate_paths",
                        lambda env, rel: [os.environ.get(env, "")] if env == "ORCH_MCP_LANE_WIP"
                        else real(env, rel))
    # ⛔ THROUGH `serve()` THIS IS THE START GATE (I5a pins that). What this case pins is the SECOND
    # line of defence: the runner's own abstention, which is what a per-tool call sees if a module
    # disappears between the gate and the call.
    payload = mod._lane_artifact(mod.Modules(), "X", {})
    assert "UNMEASURED(" in payload["words"]["unmeasured"]
    assert "not resolved" in payload["words"]["unmeasured"]


# ── I2 — an `open` issue is NEVER merged/closed/done ─────────────────────────────────────────

def _gh_stub(tmp_path, pr_payload, issue_states):
    body = """
import json, sys
args = sys.argv[1:]
if args[:2] == ['pr', 'view']:
    print(json.dumps(%r)); sys.exit(0)
if args[:2] == ['issue', 'view']:
    n = args[2]
    states = %r
    print(json.dumps({"number": int(n), "state": states.get(n, "OPEN")})); sys.exit(0)
sys.exit(2)
""" % (pr_payload, issue_states)
    return stub(tmp_path, "gh_stub.py", body)


def test_I2_a_mention_is_not_a_closure_and_an_open_issue_is_never_closed(tmp_path, monkeypatch):
    """The FALSE MERGED fixture: 7 PRs printed as merged and all seven were `open`.

    `fleet-report.py::section_p0p1` builds its "merged" list from a `#(\\d{4,5})` regex over the title,
    body and branch — so a PR that MENTIONS #5095 counts it as merged. Four fixtures, because four
    different reasons a wrong answer appears: a mention, a stale cached value, a partial response, and
    an unreadable API.
    """
    pr = {"number": 12, "state": "MERGED", "mergedAt": "2026-11-03T00:00:00Z",
          "title": "fix: also mention #5095 and #9548", "headRefName": "p0-10000",
          "body": "closes #10000. see #5095 for background.",
          "closingIssuesReferences": [{"number": 10000}]}
    # #10000 is the ONLY real closure; #5095/#9548/#10000-ish mentions must not close anything.
    monkeypatch.setenv("ORCH_MCP_GH", _gh_stub(tmp_path, pr, {"10000": "OPEN", "5095": "OPEN"}))
    mod = server_mod(monkeypatch)
    is_err, payload = one(mod, "pr.closure_audit", {"pr": 12, "repo": "o/r"})
    assert payload["closing_references"] == [10000]
    assert payload["closed"] == []
    # ⛔ THE ISSUE'S OWN RE-READ STATE DECIDES: #10000 is closed BY the PR's reference but is still OPEN,
    # so it is not closed — and the tool says so with isError.
    assert payload["still_open"] == [{"issue": 10000, "state": "OPEN"}]
    assert 5095 in payload["mentioned_but_not_closing"]
    assert 9548 in payload["mentioned_but_not_closing"]
    assert payload["mention_is_not_a_closure"] is True
    assert is_err is True, "a merge that closed nothing is not a pass"

    # …and an UNREADABLE API is not "closed": neither is it "open"
    monkeypatch.setenv("ORCH_MCP_GH", str(tmp_path / "no-such-gh"))
    is_err, payload = one(mod, "pr.closure_audit", {"pr": 12, "repo": "o/r"})
    assert is_err and "UNMEASURED(" in payload["unmeasured"]
    assert "closed" not in payload and "still_open" not in payload


# ── I3 — a finished lane is NEVER dead; no verdict is `no-verdict` with its reason ───────────

def _liveness_fixture(mod, monkeypatch, rows):
    monkeypatch.setenv("ORCH_MCP_LANE_STATUS",
                       stub_json(monkeypatch_tmp(monkeypatch), "lane_status_stub.py", rows))


def monkeypatch_tmp(monkeypatch):
    import tempfile
    d = tempfile.mkdtemp(prefix="orch-mcp-test-")
    monkeypatch.setenv("ORCH_MCP_STATE_DIR", d)
    return __import__("pathlib").Path(d)


def test_I3_a_finished_lane_is_never_dead(tmp_path, monkeypatch):
    """The FALSE DEATH x3 fixture. Three lanes that had FINISHED were reported dead and re-dispatched.

    The mapping rule that makes this impossible is not a heuristic: **a terminal RECORD decides**, and
    the process table is not consulted for it. `dead` is reachable only from `RUNNING`.
    """
    mod = server_mod(monkeypatch)
    mods = mod.Modules()
    reg = mod.Registry(mods)

    done = {"lane_id": "L-done", "state": "DONE", "heartbeat_at": 1, "budget_s": 600,
            "pid": 999999, "reason": None, "state_reason": "terminal-record",
            "artifacts": [{"kind": "pr", "value": "3419"}], "worktree": "/tmp/wt-done"}
    running_stale = {"lane_id": "L-dead", "state": "RUNNING", "heartbeat_at": 1, "budget_s": 60,
                     "pid": 999999, "worktree": "/tmp/wt-dead"}
    lv = reg.liveness
    for row, want_state, want_dead in ((done, "finished", False),):
        got = lv.read(row, [], "stub")
        assert got["state"] == want_state, got
        assert got["dead"] is want_dead, got
    # ⛔ the positive death finding is NOT `no-verdict`: it is `dead` + `dead: true` + the pending
    # owner decision, which is what §4.3 requires until §13 Q1 is answered.
    got = lv.read(running_stale, [], "stub")
    assert got["state"] == "dead", got
    assert got["dead"] is True and got["reason"] == "incarnations-absent", got
    assert "pending_owner_decision" in got and "13 Q1" in got["pending_owner_decision"]
    # …and no verdict at all is `no-verdict` WITH its reason, never `frozen`
    got = lv.read({"lane_id": "L-unread", "state": "RUNNING", "heartbeat_at": 1, "budget_s": 60,
                   "pid": 424242}, [], "stub")
    assert got["state"] in ("dead", "no-verdict"), got
    assert got["reason"], got
    assert got["state"] != "frozen" or "turn" in got["reason"], got


def test_I3b_the_liveness_axis_is_a_payload_extension_of_the_shipped_pair(tmp_path, monkeypatch):
    """`lane_status` is a DELTA on `lane.list`/`lane.show`, not a thirteenth name (decision 2).

    The tree steps are `liveness.py::evaluate`'s, and the evidence is the beat's own fleet sample — the
    step-2 CPU reader is `lane-status.py::lane_cpu_busy`, never a second sampler (inventory D7).
    """
    mod = server_mod(monkeypatch)
    mods = mod.Modules()
    reg = mod.Registry(mods)
    # ⛔ A LIVE pid AND A STALE HEARTBEAT: the pid must be a fenced HOLDER, or the ladder reads `dead`
    # before step 3 is ever reached — and a FRESH heartbeat reads `jsonl-grew` before it, because a growing
    # lane can never be dead (that ordering is a safety property, not an oversight).
    row = {"lane_id": "L1", "state": "RUNNING", "heartbeat_at": int(time_now()) - 3600,
           "budget_s": 600, "pid": os.getpid(), "worktree": "/tmp/wt1"}
    # ⛔ THE FIXTURE SPEAKS THE PRODUCER'S OWN SCHEMA. It used to pass `cpu_busy` and a BOOLEAN
    # `child_stale` — NEITHER of which `lane-status.py --json` emits. `cpu_busy` exists only as a
    # `classify()` keyword there (the row's key is `cpu`), and `child_stale` is an AGE IN SECONDS. So
    # this arm asserted that the join worked against an invented contract: it passed green over a
    # production path where step 2 was permanently UNMEASURED and step 3's veto was dropped for any
    # child older than one second. The keys here are exactly the row's.
    lane_rows = [{"ws": "WS1", "cwd": "/tmp/wt1", "cpu": True, "cpu_any": True,
                  "child": "kid-sid-1", "child_stale": 12, "child_grew": True}]
    got = reg.liveness.read(row, lane_rows, "stub", tree=True)
    assert got["state"] == "working", got          # step 3 veto: child in flight
    assert got["reason"] == "child-in-flight", got
    assert got["evidence_source"]["step2"]["cpu"] is True
    assert got["children"]["child"] == "kid-sid-1"
    assert got["children"]["via"].startswith("liveness.gather")
    vocab = list(mod.Liveness.SURFACE) + ["dead"]
    assert got["state"] in vocab


def test_I3c_the_join_reads_the_producers_real_schema(monkeypatch):
    """The step-2/3 join is pinned against `lane-status.py`'s ACTUAL row keys, not a guessed contract.

    Three defects this arm exists to catch, all measured on the pre-fix code:
      1. `cpu_busy` is not a row key (the row carries `cpu` / `cpu_any`), so step 2 was always
         `advanced=None` — permanently unmeasured — while the payload published
         `source="lane-status.py::lane_cpu_busy"`, i.e. claimed a measurement nobody took.
      2. `child_stale` is `int(time.time() - mtime)`, an AGE. `bool()` on it says "stale" for any
         child older than one second, dropping the step-3 veto the step exists to provide.
      3. An ABSENT `cpu` must abstain, never be reported as a measurement.
    """
    mod = server_mod(monkeypatch)
    mods = mod.Modules()
    reg = mod.Registry(mods)
    row = {"lane_id": "L1", "state": "RUNNING", "heartbeat_at": int(time_now()) - 3600,
           "budget_s": 600, "pid": os.getpid(), "worktree": "/tmp/wt1"}
    # (1) a FRESH child (age 12 s, far under the producer's ABANDON_S) must VETO.
    got = reg.liveness.read(row, [{"ws": "WS1", "cwd": "/tmp/wt1", "cpu": None,
                                   "child": "kid-1", "child_stale": 12}], "stub", tree=True)
    assert got["reason"] == "child-in-flight", got
    # (2) an ABANDONED child (past ABANDON_S) must NOT veto — the ladder stays free to call it wedged.
    got = reg.liveness.read(row, [{"ws": "WS1", "cwd": "/tmp/wt1", "cpu": None,
                                   "child": "kid-1", "child_stale": mod.CHILD_ABANDON_S + 1}],
                            "stub", tree=True)
    assert got["reason"] != "child-in-flight", got
    # (3) and with no `cpu` attribution the sample says UNMEASURED rather than claiming a source.
    got = reg.liveness.read(row, [{"ws": "WS1", "cwd": "/tmp/wt1"}], "stub", tree=True)
    step2 = got["evidence_source"]["step2"]
    assert step2["cpu"] is None and "UNMEASURED" in step2["unmeasured"], step2


def test_I3d_CHILD_ABANDON_S_mirrors_the_producer(monkeypatch):
    """`CHILD_ABANDON_S` is a COPY of `lane-status.py`'s `ABANDON_S`, so it is pinned against it.

    `lane-status.py` runs as a SUBPROCESS here, so the bound cannot be imported — it is re-declared,
    which means it can drift. A drifted bound is silent by construction: too small and a live child
    stops vetoing (the finding this whole step answers), too large and an abandoned record masks a
    real wedge. This arm reads the producer's own definition and reds on any difference.
    """
    import re
    src = open(os.path.join(_HERE, "..", "..", "scripts", "lane-status.py"),
               encoding="utf-8").read()
    m = re.search(r"^ABANDON_S\s*=\s*(.+?)\s*(?:#.*)?$", src, re.M)
    assert m, "lane-status.py no longer defines ABANDON_S — the mirror must be re-derived"
    expr = m.group(1)
    # Only a literal product of ints is accepted: this must not become an eval of arbitrary source.
    assert re.fullmatch(r"[0-9]+(?:\s*\*\s*[0-9]+)*", expr), (
        "ABANDON_S is no longer an int literal product: %r — re-derive the mirror by hand" % expr)
    want = 1
    for part in expr.split("*"):
        want *= int(part.strip())
    got = server_mod(monkeypatch).CHILD_ABANDON_S
    assert got == want, ("server.CHILD_ABANDON_S=%d != lane-status.py ABANDON_S=%d" % (got, want))


def time_now():
    import time
    return int(time.time())


# ── I4 — every number carries its measurement time and a correctly-computed age ─────────────

def test_I4a_a_future_stamp_is_clamped_and_never_renders_a_negative_age(tmp_path):
    """The STALE CLOCK fixture's inverse: `as of 14:16, 0m ago` for a five-hour-old stamp.

    An age that is always zero is not an age — and a NEGATIVE age (`-4m ago`) is the same defect with
    the sign flipped. `beta-progress.py` clamps at render; this pins the clamp, red-first in I6.
    """
    home = tmp_path / "home"
    (home / ".pi" / "agent" / "state").mkdir(parents=True)
    cache = home / ".pi" / "agent" / "state" / "beta-progress.json"
    future = int(time_now()) + 299
    cache.write_text(json.dumps({"ts": future, "open_prs": 3, "merged_today": 1,
                                 "p0": {"open": 2, "with_pr": 1, "without": 1},
                                 "p1": {"open": 4, "with_pr": 2, "without": 2}}))
    ran = subprocess.run([sys.executable, os.path.join(_HERE, "..", "..", "scripts",
                                                       "beta-progress.py"), "--json"],
                         capture_output=True, text=True, timeout=60,
                         env=dict(os.environ, HOME=str(home)))
    assert ran.returncode == 0, ran.stderr
    payload = json.loads(ran.stdout)
    assert payload["readable"] is True
    assert payload["age_m"] == 0, payload           # CLAMPED, never `-4`
    assert payload["measured_at"] > 0 and payload["stamp"]
    assert payload["repo"] == "daniel-ospina/tortoise"


def test_I4b_every_census_figure_carries_a_time_and_a_source(tmp_path, monkeypatch):
    mod = server_mod(monkeypatch)
    monkeypatch.setenv("ORCH_MCP_BETA_PROGRESS", stub_json(
        tmp_path, "beta.py", {"repo": "o/r", "readable": True, "measured_at": 1, "age_m": 0,
                              "stamp": "00:00", "open_prs": 1, "merged_today": 0,
                              "p0": {"open": 0, "with_pr": 0, "without": 0},
                              "p1": {"open": 0, "with_pr": 0, "without": 0}}))
    monkeypatch.setenv("ORCH_MCP_CAPACITY", stub(tmp_path, "cap.sh", "print('probe: ok')"))
    monkeypatch.setenv("ORCH_MCP_BOX_STATUS", stub(tmp_path, "box.sh", "print('harness: abc')"))
    monkeypatch.setenv("ORCH_MCP_CMUX", "")
    is_err, payload = one(mod, "fleet.census", {"repos": ["o/r"]})
    assert payload["measured_at"] > 0
    assert payload["repos"]["o/r"]["measured_at"] == 1
    for key in ("capacity", "status"):
        assert payload["box"][key]["measured_at"] > 0
        assert payload["box"][key]["source"]
    load = payload["box"]["load"]
    assert load["measured_at"] > 0 and load["source"] == "os.getloadavg()"
    assert load["platform"] in ("macos", "linux")
    # ⛔ THE PLATFORM NAMES WHICH OF THE TWO CALIBRATIONS APPLIES (inventory §10.1)
    assert load["applicable_ceiling_lpc"] in (1.2, 10.0)
    assert load["applicable_threshold_source"]
    assert "caveat" in load


# ── I5 — instrument_versions() and the START GATE ───────────────────────────────────────────

def test_I5a_missing_module_refuses_to_start_and_names_it(monkeypatch, capsys):
    """A module deleted from the deployed tree must stop the server, not degrade it.

    ⛔ The exit-2/unreadable case is the one a naive implementation passes: `unknown` treated as a pass is
    the `no-op gate` failure class, so `deployed_drift` says `unknown` and never `ok`.
    """
    mod = _load(_SERVER, "orchestrator_mcp_under_test")
    real = mod._candidate_paths

    def fake(env_name, relpath):
        if env_name == "ORCH_MCP_BETA_PROGRESS":
            return [os.path.join("/nonexistent", "beta-progress.py")]
        return real(env_name, relpath)

    monkeypatch.setattr(mod, "_candidate_paths", fake)
    import io as _io
    err = _io.StringIO()
    old = sys.stderr
    sys.stderr = err
    try:
        rc = mod.serve(_io.StringIO(""), _io.StringIO())
    finally:
        sys.stderr = old
    assert rc == 3, "invariant 5: the server REFUSES to start when a wrapped module is missing"
    text = err.getvalue()
    assert "MISSING beta_progress" in text, text
    assert "beta-progress.py" in text


def test_I5b_instrument_versions_lists_every_module_and_reports_drift_as_unknown(tmp_path,
                                                                               monkeypatch):
    mod = server_mod(monkeypatch)
    versions = mod.instrument_versions(mod.Modules())
    assert versions["ok"] is True
    keys = [row["module"] for row in versions["modules"]]
    assert keys == [row[0] for row in mod.WRAPPED]
    for row in versions["modules"]:
        assert len(row["sha256"]) == 64, row
        assert row["present"] is True
    # ⛔ the provenance half is DECLARED as `unknown`, never reported as a pass
    assert versions["deployed_drift"].startswith("unknown(")
    # a DRIFTED module is detectable: change one byte, the sha changes
    target = tmp_path / "beta.py"
    target.write_text("print('v1')\n")
    monkeypatch.setenv("ORCH_MCP_BETA_PROGRESS", str(target))
    monkeypatch.setattr(mod, "_candidate_paths",
                        lambda env, rel: [os.environ.get(env, "")] if env == "ORCH_MCP_BETA_PROGRESS"
                        else [os.path.abspath(os.path.join(_HERE, "..", "..", rel))])
    first = {r["module"]: r["sha256"] for r in mod.instrument_versions(mod.Modules())["modules"]}
    target.write_text("print('v2')\n")
    second = {r["module"]: r["sha256"] for r in mod.instrument_versions(mod.Modules())["modules"]}
    assert first["beta_progress"] != second["beta_progress"]
    assert first["lane_registry"] == second["lane_registry"]


# ── I6 — MUTATION, RED FIRST (the pre-fix blob is in git) ──────────────────────────────────

def test_I6_the_stale_clock_fixture_is_RED_against_the_pre_fix_blob(tmp_path):
    """#3 STALE CLOCK: the pre-fix line IS in git, so "fails without the fix" is an EXECUTED claim.

    `git show b54b117fc:scripts/beta-progress.py` renders `age_m = int((time.time() - ts) / 60)` with no
    clamp and no future-stamp validation — so a future stamp prints a NEGATIVE age while HEAD clamps it.
    """
    root = os.path.abspath(os.path.join(_HERE, "..", ".."))
    blob = subprocess.run(["git", "-C", root, "show", "b54b117fc:scripts/beta-progress.py"],
                          capture_output=True, text=True)
    if blob.returncode != 0:
        pytest.skip("the pre-fix blob b54b117fc is not in this clone")
    prefix = tmp_path / "prefix.py"
    prefix.write_text(blob.stdout)
    home = tmp_path / "home"
    (home / ".pi" / "agent" / "state").mkdir(parents=True)
    (home / ".pi" / "agent" / "state" / "beta-progress.json").write_text(json.dumps(
        {"ts": int(time_now()) + 299, "open_prs": 1, "merged_today": 0,
         "p0": {"open": 0, "with_pr": 0, "without": 0}, "p1": {"open": 0, "with_pr": 0, "without": 0}}))
    head = subprocess.run([sys.executable, os.path.join(root, "scripts", "beta-progress.py")],
                          capture_output=True, text=True, timeout=60,
                          env=dict(os.environ, HOME=str(home)))
    old = subprocess.run([sys.executable, str(prefix)], capture_output=True, text=True, timeout=60,
                         env=dict(os.environ, HOME=str(home)))
    assert old.returncode == 0 and head.returncode == 0, (old.stderr, head.stderr)
    # RED first: the pre-fix line renders a NEGATIVE age …
    assert "as of" in old.stdout and " -" in old.stdout, old.stdout
    assert "0m ago" in head.stdout, head.stdout
    assert " -" not in head.stdout, head.stdout


# ── the ten tools: one test per wrapped implementation ──────────────────────────────────────

def test_T_lane_artifact_maps_the_words_and_files_axes(tmp_path, monkeypatch):
    # ⛔ PIN THE STATE DIR — the board read is an INPUT, so the test must supply it (#3577 CI red).
    # `server_mod` sets ORCH_MCP_STATE_DIR to `""`, which `_state_dir()` reads as UNSET and resolves
    # against the ambient `$CELL_HOME`/`$HOME`. On a dev box `~/.pi/agent/state` EXISTS, so the read
    # yields the dict arm by luck; on a fresh runner it does not, `os.listdir` raises OSError, and
    # `_lane_done_line` returns its NAMED ABSTENTION — a STRING — so indexing `["value"]` raised
    # `TypeError`. Green on the author's machine, red on every runner: a test that never controlled
    # its own input. `monkeypatch_tmp` is this suite's existing idiom for exactly that pin.
    mod = server_mod(monkeypatch)
    monkeypatch_tmp(monkeypatch)
    ok = stub_json(tmp_path, "wip_ok.py", {"lane": "L1", "verdict": "WIP-IDLE", "turns": ["wip"],
                                           "measured_at": 1})
    monkeypatch.setenv("ORCH_MCP_LANE_WIP", ok)
    monkeypatch.setenv("ORCH_MCP_LANE_ARTIFACTS", stub(tmp_path, "arts.py", "print('found')"))
    is_err, payload = one(mod, "lane.artifact", {"lane": "L1", "pattern": "ci-cause"})
    assert is_err is False
    assert payload["words"]["outcome"] == "ANSWERED"
    assert payload["files"]["outcome"] == "FOUND"
    assert payload["terminal_verdict"]["value"] == "none written"

    # rc 3 = UNMEASURED (activity unreadable) — never "idle", never an error
    monkeypatch.setenv("ORCH_MCP_LANE_WIP",
                       stub_json(tmp_path, "wip_unm.py", {"unmeasured": "UNMEASURED(x + y)"}, code=3))
    is_err, payload = one(mod, "lane.artifact", {"lane": "L1"})
    assert payload["words"]["outcome"] == "UNMEASURED"
    assert payload["words"]["exit_code"] == 3
    # rc 2 = NO-LANE (usage) — a caller bug, and the tool says which
    monkeypatch.setenv("ORCH_MCP_LANE_WIP",
                       stub_json(tmp_path, "wip_none.py", {"note": "no lane matches"}, code=2))
    is_err, payload = one(mod, "lane.artifact", {"lane": "NOPE"})
    assert payload["words"]["outcome"] == "NO-LANE"
    # rc 3 on the FILES axis is a VALUE, not an error
    monkeypatch.setenv("ORCH_MCP_LANE_ARTIFACTS", stub(tmp_path, "arts3.py", "print('none')", code=3))
    is_err, payload = one(mod, "lane.artifact", {"lane": "L1", "name": "x"})
    assert payload["files"]["outcome"] == "ABSENT-EVERYWHERE"

    # ⛔ AN UNREADABLE BOARD DIR IS AN ABSTENTION, NOT "none written" — and the two are DIFFERENT
    # SHAPES, which is what this case pins. MUTANT that reddens it: `_lane_done_line` returning
    # `{"value": "none written"}` from its `except OSError` arm — claiming a MEASURED absence from a
    # directory it could not read, which is the false VALUE the impl's own docstring forbids.
    monkeypatch.setenv("ORCH_MCP_STATE_DIR", str(tmp_path / "no-such-state-dir"))
    is_err, payload = one(mod, "lane.artifact", {"lane": "L1"})
    assert isinstance(payload["terminal_verdict"], str), payload["terminal_verdict"]
    assert payload["terminal_verdict"].startswith("UNMEASURED(read board dir "), payload


def test_T_pr_queue_maps_the_fifteen_actions_onto_the_six_classes(tmp_path, monkeypatch):
    mod = server_mod(monkeypatch)
    rows = [{"pr": 1, "action": "LAND"}, {"pr": 2, "action": "carry-patch"},
            {"pr": 3, "action": "CLOSE-STALE"}]
    monkeypatch.setenv("ORCH_MCP_PR_STATE",
                       stub(tmp_path, "prs.py", "import json\nprint(json.dumps(%r))" % rows))
    is_err, payload = one(mod, "pr.queue", {"repo": "o/r"})
    assert is_err is False
    by_pr = {r["pr"]: r for r in payload["rows"]}
    assert by_pr[1]["class"] == "READY" and by_pr[1]["action"] == "LAND"
    assert by_pr[2]["class"] == "UNMAPPED"          # the 15 remain the answer; the 6 are a VIEW
    assert by_pr[3]["class"] == "STALE-ATTESTATION"
    assert payload["classes_unmapped"] == 1
    # ⛔ exit 2 = the pass could not be made → an unreadable board is NOT an empty queue
    monkeypatch.setenv("ORCH_MCP_PR_STATE",
                       stub(tmp_path, "prs2.py", "import sys\nsys.stderr.write('boom')\n", code=2))
    is_err, payload = one(mod, "pr.queue", {"repo": "o/r"})
    assert is_err and "UNMEASURED(" in payload["unmeasured"]
    assert "rows" not in payload


def test_T_claim_check_is_an_abstention_and_never_freedom(tmp_path, monkeypatch):
    mod = server_mod(monkeypatch)
    payload_in = {"readable": True, "present": True, "read_detail": "ok",
                  "claims": [{"kind": "issue", "issue": "1850", "owner": "h:1"},
                             {"kind": "head", "pr": "77", "sha12": "abcdef123456"}],
                  "verdict": {"state": "unknown", "reason": "claim-held"}, "advisory": "ADVISORY"}
    monkeypatch.setenv("ORCH_MCP_CLAIM_LANES",
                       stub(tmp_path, "cl.py", "import json\nprint(json.dumps(%r))" % payload_in))
    is_err, payload = one(mod, "claim.check", {"issue": 1850, "repo": "/tmp/x"})
    assert is_err is False
    assert payload["abstention"] is True and "never freedom" in payload["abstention_note"]
    assert payload["issue_present"] is True and payload["issue_claims"][0]["owner"] == "h:1"
    # ⛔ no repo is a TYPED REFUSAL, not a failed read and not "no claims"
    is_err, payload = one(mod, "claim.check", {"issue": 1850})
    assert is_err and payload["refused"] == "repo-required"


def test_T_review_record_reports_the_verdict_and_its_next_action(tmp_path, monkeypatch):
    mod = server_mod(monkeypatch)
    stubdir = tmp_path

    def body(line, code):
        return stub(stubdir, "rr%d.py" % code, "print(%r)" % line, code=code)

    monkeypatch.setenv("ORCH_MCP_RECORD_REVIEW", body("head\tabc\tdef", 0))
    is_err, payload = one(mod, "pr.review_record", {"pr": 9, "repo": "o/r"})
    assert is_err is False and payload["state"] == "current"
    assert payload["record_digest"] == "abc" and payload["live_digest_or_status"] == "def"
    assert "step 1 of 5" in payload["landing_contract"]

    monkeypatch.setenv("ORCH_MCP_RECORD_REVIEW", body("carry-patch\tabc\tdef", 6))
    is_err, payload = one(mod, "pr.review_record", {"pr": 9})
    assert is_err is True, "a stale record is an ACTION, not a pass"
    assert payload["state"] == "stale" and "RE-RECORD" in payload["next_action"]

    monkeypatch.setenv("ORCH_MCP_RECORD_REVIEW", body("nodigest\t-\t-", 5))
    is_err, payload = one(mod, "pr.review_record", {"pr": 9})
    assert payload["verdict"] == "nodigest" and payload["state"] == "absent"
    # …and a script that answers with NO tab-separated line is UNMEASURED, not "absent"
    monkeypatch.setenv("ORCH_MCP_RECORD_REVIEW",
                       stub(tmp_path, "rr_notab.py", "print('prose only, no verdict row')"))
    is_err, payload = one(mod, "pr.review_record", {"pr": 9})
    assert is_err and "UNMEASURED(" in payload["unmeasured"]


def test_T_box_exec_refuses_a_shell_string_and_a_non_allowlisted_argv(tmp_path, monkeypatch):
    """⛔ THE ALLOWLIST IS ONLY REAL ON AN ARGV SURFACE.

    Claude Code's own security docs: a deny/allow rule "doesn't match the same program by path or inside
    `sh -c`". So a shell string is refused BY TYPE, and a command outside the allowlist is a TYPED
    REFUSAL — never a pass-through.
    """
    mod = server_mod(monkeypatch)
    cmux = stub(tmp_path, "cmux.sh", "print('ok')")
    monkeypatch.setenv("ORCH_MCP_CMUX", cmux)

    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": "rm -rf /"})
    assert is_err and payload["refused"] == "argv-must-be-a-list-of-strings"
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["rm", "-rf", "/"]})
    assert is_err and payload["refused"] == "command-not-allowlisted"
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["curl", "http://x"]})
    assert is_err and payload["refused"] == "command-not-allowlisted"
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["git", "push"]})
    assert is_err and payload["refused"] == "command-not-allowlisted"
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["uname", "|", "sh"]})
    assert is_err and payload["refused"] == "command-not-allowlisted"
    # ⛔ A WRITE-ESCAPE IS NOT A SHELL METACHARACTER, SO THE METACHAR FILTER MISSES IT (measured:
    # `git show --output=/tmp/x HEAD` -> rc=0, 7762 B written; `git log --output=` 2038 B). Every
    # verb in `GIT_OK_VERBS` accepts it, so the "FAIL-CLOSED: never a pass-through" gate was a
    # write channel to the cell, and `cat` was the read-back. Refused BY SHAPE, on every verb.
    for esc in (["git", "show", "--output=/tmp/pwn.sh", "HEAD"],
                ["git", "log", "--output=/tmp/pwn.sh", "-1"],
                ["git", "diff", "--output=/tmp/pwn.sh"],
                ["git", "show", "--outfile=/tmp/pwn.sh", "HEAD"],
                ["git", "show", "--output", "/tmp/pwn.sh", "HEAD"],
                ["git", "show", "--OUTPUT=/tmp/pwn.sh", "HEAD"]):
        is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": esc})
        assert is_err and payload["refused"] == "command-not-allowlisted", (esc, payload)
        assert "write" in payload["reason"], (esc, payload["reason"])

    # ⛔ `hostname` WITH A BARE ARGUMENT *RENAMES THE BOX*. `hostname NAME` and `hostname -F <file>` are
    # the SETTER form; `ALLOWLIST["hostname"] = ([], 1)` bounds only the COUNT, so both passed a gate
    # whose refusal text says the surface is "allowlisted for READING". A rename is not cosmetic here:
    # `lane_registry.short_host()` is baked into every record's `host` and every minted `lane_id`, so
    # the box's new records stop matching its existing ones and host-scoped claim/ownership reads
    # degrade to abstentions. Verified ALLOWED before this arm existed.
    for argv in (["hostname", "pwned-cell"], ["hostname", "-F/etc/hostname"],
                 ["hostname", "-F", "/etc/hostname"]):
        is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": argv})
        assert is_err and payload["refused"] == "command-not-allowlisted", (argv, payload)
        # The two-argument `-F <file>` form is refused EARLIER, by `max_args` — also correct, and also
        # a reason that names no falsehood, so only the flag-gate cases are asserted on their wording.
        if len(argv) == 2:
            assert "host name" in payload["reason"], (argv, payload["reason"])
    # …and the QUERY forms still work (a gate that refuses its own purpose is also broken).
    for argv in (["hostname"], ["hostname", "-f"]):
        assert mod._allowlisted(argv)[0] is True, argv

    # ⛔ THE ALLOWLIST PINS A **NAME**, SO A PATH MAY NOT RIDE THROUGH IT. `prog = basename(argv[0])`
    # let `["/tmp/evil/git", "status"]`, `["./git", "status"]` and `["../../bin/git", "log"]` all pass
    # (verified) — i.e. ANY file named an allowlisted program, at a CALLER-CHOSEN path, executed under
    # this surface's authority. `/tmp` on a cell is writable by anything else running there, so a
    # planted `git`/`ls` was reachable through a gate whose own contract says a non-allowlisted command
    # is "a TYPED REFUSAL, never a pass-through" and whose cited rationale is that a rule "doesn't
    # match the same program by path".
    for argv in (["/tmp/evil/git", "status"], ["./git", "status"], ["../../bin/git", "log"],
                 ["/tmp/evil/ls", "/"], ["/tmp/x/cat", "/etc/passwd"], ["sub/dir/whoami"]):
        is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": argv})
        assert is_err and payload["refused"] == "command-not-allowlisted", (argv, payload)
        assert "PROGRAM NAME" in payload["reason"], (argv, payload["reason"])
    # …and the bare name still works.
    assert mod._allowlisted(["git", "status"])[0] is True

    # ⛔ THE DECLARED PREFIX IS ENFORCED, NOT UNPACKED AND IGNORED — the mechanism that let
    # `hostname NAME` through, pinned on a SYNTHETIC entry so it survives a future edit to the real
    # ALLOWLIST. Without this, the check reads as dead code (it WAS: `prefix` had no other use) and the
    # next reader deletes it.
    monkeypatch.setitem(mod.ALLOWLIST, "ps", (["-eo", "pid"], 3))
    assert mod._allowlisted(["ps", "-eo", "pid"])[0] is True
    assert mod._allowlisted(["ps", "-ef"])[0] is False, "the declared prefix must be required"
    assert mod._allowlisted(["ps", "-eo", "pid", "-x"])[0] is True      # beyond the prefix: bounded
    assert mod._allowlisted(["ps", "-eo", "pid", "-x", "-y"])[0] is False  # max_args

    # ⛔ AND THE WRITE-ESCAPE BAN IS SCOPED TO `git`, the one allowlisted program with a
    # caller-NAMED output file. Applying it to every program false-blocked a READ-ONLY call and
    # stated a falsehood doing it: GNU `df --output=FIELD_LIST` only selects COLUMNS
    # (`df --output=source` writes nothing), so a legitimate diagnostic was refused with "writes a
    # file the caller names" — wrong about the command and wrong about the reason.
    assert mod._allowlisted(["df", "-h", "--output=source"])[0] is True
    assert mod._allowlisted(["df", "/"])[0] is True
    assert mod._allowlisted(["free", "-h"])[0] is True

    # …and an ALLOWLISTED argv runs, with the five typed fields
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["uname", "-s"]})
    assert is_err is False, payload
    for field in ("rc", "stdout", "timed_out", "truncated"):
        assert field in payload, field
    assert payload["outcome"] == "RAN"
    assert payload["channel_only"].startswith("timed_out and truncated")
    # ⛔ read-only mode gates it hardest of all
    mod_ro = _load(_SERVER, "orchestrator_mcp_ro")
    monkeypatch.setenv("ORCH_MCP_READ_ONLY", "1")
    is_err, payload = one(mod_ro, "box.exec", {"box": "pi-cell-1", "argv": ["uname"]})
    assert is_err and payload["refused"] == "read-only"


def test_T_box_exec_reports_a_LINK_REFUSAL_as_a_channel_fact_not_the_commands_rc(
        tmp_path, monkeypatch):
    """agent-infra#2345 — the peer never ran the command, so its rc is not the command's verdict.

    MEASURED 2026-11-08 from `pi-cell-5`: `cmux vm ls --json` printed `"reachable":true` for all four
    peers while `cmux vm exec <peer> -- hostname` failed against all four. Before this arm the payload
    said `outcome: NONZERO, rc: 3` — indistinguishable from "the peer ran it and it failed", which
    sends the operator to the command, or to the peer's state, when neither is what refused.
    The three causes have three DIFFERENT remedies, so each is named. Arms 1–3 FAIL on the
    pre-fix code (which returned NONZERO/RAN and carried no `refused` key at all); arm 4 is a
    REGRESSION PIN, not a failing-first arm — it asserts the same `RAN` shape the pre-fix code
    returned, which is exactly what a pin must do. Arms 5–6 bound the CLASS rather than an instance
    (`ps`/`pgrep` precedent at ALLOWLIST): 5 is a peer that PRINTS a refusal phrase (the streams are
    shared with the relay, so an unanchored pattern re-labelled it), and 6 is a transport that both
    refused and timed out (whose `channel_only` note the refusal used to replace).
    """
    mod = server_mod(monkeypatch)

    def refusal_stub(name, body, code):
        return stub(tmp_path, name, body, code=code)

    # (1) the common case: the client refuses the route before the peer is asked anything
    monkeypatch.setenv("ORCH_MCP_CMUX", refusal_stub(
        "cmux_link3.py",
        "import sys\n"
        "if 'exec' in sys.argv[1:]:\n"
        "    sys.stderr.write(\"cmux: link to 'pi-cell-4' exited; see "
        "/home/cmux/.cmux/peer-links/pi-cell-4.log\\n\")\n"
        "    sys.exit(3)\n"
        "print('pi-cell-4  vm-ce2c  running  reachable  linked')\n", 0))
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-4", "argv": ["uname", "-s"]})
    assert is_err is True, payload
    assert payload["outcome"] == "CHANNEL-REFUSED", payload
    assert payload["channel_refused"] == "link-refused", payload
    assert payload["peer"] == "pi-cell-4", payload
    assert payload["peer_log"].endswith("peer-links/pi-cell-4.log"), payload
    # ⛔ `refused` KEEPS ITS FAIL-CLOSED MEANING. In this file it already means "this surface ran
    # NOTHING" (`read-only`, `argv-must-be-a-list-of-strings`, `command-not-allowlisted`, …) — all of
    # which return before the transport is invoked. A link refusal DID invoke it and is reporting the
    # CHANNEL, so it must not land in the key a caller switches on to mean "amend my request".
    assert "refused" not in payload, payload
    assert "never the command's verdict" in payload["channel_only"], payload
    assert "timed_out and truncated are CHANNEL facts" in payload["channel_only"], payload
    assert "carrier" in payload["refusal_detail"], payload
    assert "fail_open" not in payload, "a non-zero rc is not the fail-open form"

    # (2) THE FAIL-OPEN FORM: measured on `pi-cell-3` (2026-10-23 issue comment) — the transport
    #     refuses the link AND exits 0, so a caller keying on `rc` alone reads a dead link as success.
    monkeypatch.setenv("ORCH_MCP_CMUX", refusal_stub(
        "cmux_link0.py",
        "import sys\n"
        "sys.stderr.write(\"cmux: link to 'pi-cell-3' exited; see /tmp/cell-home/.cmux/peer-links/"
        "pi-cell-3.log\\n\")\n", 0))
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-3", "argv": ["uname"]})
    assert is_err is True, payload           # rc=0 must NOT read as RAN
    assert payload["outcome"] == "CHANNEL-REFUSED", payload
    assert payload["rc"] == 0 and "fail_open" in payload, payload
    assert "only `rc` reads this as success" in payload["fail_open"], payload

    # (2b) THE THIRD CLASS, WHICH HAD NO ARM AT ALL: deleting its pattern left the suite green, so the one
    #      remedy the tool description and both inventory rows sell to callers (pairing/registry on THIS
    #      box) was unpinned — a class advertised but untested. Measured STANDING ALONE as exec output
    #      (`cmux vm exec pi-cell-1 -- hostname`, #2345, 2026-11-02), not only as the peer log's tail.
    #      ⛔ AND A `peer-links/…` PATH SITS ON ANOTHER LINE, so this arm also pins that `peer_log` is read
    #      from the MATCHED line — whole-buffer `PEER_LOG_RE` attached a peer's own sha256sum output to a
    #      class the inventory rows say never carries one.
    monkeypatch.setenv("ORCH_MCP_CMUX", refusal_stub(
        "cmux_nodaemon.py",
        "import sys\n"
        "sys.stdout.write('9f2c  /home/cmux/.cmux/peer-links/pi-cell-4.log\\n')\n"
        "sys.stderr.write('cmux-tui: no known daemon matches this route; connect with an "
        "invitation\\n')\n", 1))
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-4", "argv": ["uname"]})
    assert is_err is True and payload["channel_refused"] == "no-known-daemon", payload
    assert "no pairing" in payload["refusal_detail"], payload
    assert "peer" not in payload, payload
    assert "peer_log" not in payload, "a peer-links path from another line is not this class's peer log"
    assert payload["refusal"].startswith("cmux-tui: no known daemon"), payload

    # (3) the OTHER root: this CALLING box has no `cmux-tui` (#3195), so every peer refuses at once.
    #     Its remedy is here, not on the peer — so it must not be reported as a peer-pairing problem.
    monkeypatch.setenv("ORCH_MCP_CMUX", refusal_stub(
        "cmux_nobin.py",
        "import sys\n"
        "sys.stderr.write('cmux: cmux-tui daemon binary not found at "
        "/root/.cmux/bin/cmux-tui\\n')\n", 1))
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["uname"]})
    assert is_err is True and payload["channel_refused"] == "daemon-binary-absent", payload
    assert "calling box" in payload["refusal_detail"], payload
    # ⛔ THE PATH GROUP IS CARRIED, NOT DECLARED AND DROPPED — it is the datum the CALLING-box remedy
    # needs (where `cmux-tui` was looked for), and a named group nothing reads is how the next reader
    # concludes the regex is decorative.
    assert payload["binary_path"] == "/root/.cmux/bin/cmux-tui", payload
    assert "peer" not in payload, "no peer refused — this box has no client"
    # (3b) THE BARE FORM OF THE SAME DIAGNOSTIC — the transport does NOT always prefix it. Measured on
    #      `pi-cell-2` (`cmux vm exec pi-cell-2 -- true`); #2345 carries it. Requiring `^cmux: ` silently
    #      disabled this whole class on exactly the boxes #3195 is about, so the prefix is optional here.
    #      ⛔ AND THE LINE THAT PRINTED IT IS THE CALLING BOX (pi-cell-1), not the target (pi-cell-2) — the
    #      distinction this class exists for: the remedy is on the CALLING box, #3195.
    monkeypatch.setenv("ORCH_MCP_CMUX", refusal_stub(
        "cmux_nobin_bare.py",
        "import sys\n"
        "sys.stderr.write('cmux-tui daemon binary not found at "
        "/home/cmux/.cmux/bin/cmux-tui\\n')\n", 1))
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-2", "argv": ["uname"]})
    assert is_err is True and payload["channel_refused"] == "daemon-binary-absent", payload
    assert payload["binary_path"] == "/home/cmux/.cmux/bin/cmux-tui", payload
    assert payload["refusal"].startswith("cmux-tui daemon binary not found at"), payload

    # (4) AND A REAL RUN IS NOT CLASSIFIED. The classifier matches the TRANSPORT's refusal, so a peer
    #     that answers must still be `RAN` with no refusal key — otherwise the fix hides real output.
    monkeypatch.setenv("ORCH_MCP_CMUX", stub(tmp_path, "cmux_ok.py", "print('Linux')", code=0))
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["uname", "-s"]})
    assert is_err is False, payload
    assert payload["outcome"] == "RAN" and payload["stdout"].strip() == "Linux", payload
    assert "refused" not in payload and "channel_refused" not in payload, payload

    # (5) ⛔ THE CLASS BOUND, NOT ONE BENIGN ARGV: a peer's RELAYED output carrying the refusal PHRASE
    #     (un-prefixed) is a run. `cmux vm exec` relays the remote command's streams into the very two
    #     the classifier reads, so an unanchored pattern re-labelled this `CHANNEL-REFUSED` + `fail_open`
    #     — the symmetric mis-verdict to #2345 ("the peer ran it and failed" → "the peer never ran it").
    #     ⛔ THE FIXTURE IS A SYNTHETIC BARE PHRASE, AND THAT IS ALL IT CLAIMS: the pattern requires the
    #     measured `cmux-tui: ` prefix, so an un-prefixed occurrence — which #2345 has measured NEITHER as
    #     transport output NOR as log content (both carry the prefix) — must never classify. What bounds a
    #     peer from printing the PREFIXED line is the allowlist, not the anchor (see LINK_REFUSAL_CLASSES).
    #     The daemon-binary line is NOT a valid echo fixture: the transport has been measured emitting it
    #     BOTH ways (#2345, `pi-cell-2`), so that arm lives in (3b) instead.
    monkeypatch.setenv("ORCH_MCP_CMUX", stub(
        tmp_path, "cmux_relay.py",
        "import sys\n"
        "sys.stdout.write('no known daemon matches this route; connect with an invitation\\n')\n"
        "sys.stdout.write('peer log pid=1 nmode=owner\\n')\n", 0))
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["uname"]})
    assert is_err is False and payload["outcome"] == "RAN", payload
    assert "channel_refused" not in payload and "fail_open" not in payload, payload
    # …AND THE SAME FOR THE OTHER TWO CLASSES' ANCHORS, which arm 5 pinned for `no-known-daemon` only. A
    # peer that mentions either phrase MID-LINE is still a run — dropping the `^` from either pattern left
    # the suite GREEN, i.e. half the declared class bound was unpinned and a future edit could revert it
    # silently.
    monkeypatch.setenv("ORCH_MCP_CMUX", stub(
        tmp_path, "cmux_relay_midline.py",
        "import sys\n"
        "sys.stdout.write(\"note: cmux: link to 'pi-cell-4' exited here previously\\n\")\n"
        "sys.stdout.write(\"see cmux-tui daemon binary not found at /x for the older box\\n\")\n", 0))
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["uname"]})
    assert is_err is False and payload["outcome"] == "RAN", payload
    assert "channel_refused" not in payload, payload

    # (6) ⛔ A REFUSAL **AND** A TIMEOUT: both facts stay in the payload, and `channel_only` keeps the
    #     sentence that says `timed_out`/`truncated` are channel readings. The pre-fix ordering returned
    #     the refusal FIRST and `payload.update(refusal)` REPLACED that sentence, so `timed_out: true`
    #     arrived with nothing left saying it was not evidence about the box.
    #     ⛔ AND A NOISE LINE COMES FIRST, so `refusal` is pinned to the MATCHED line rather than to the
    #     first line of the buffer (the pre-fix field was `text.strip().splitlines()[0]`).
    refusal_text = ("cmux: warning: peer cache stale\n"
                    "cmux: link to 'pi-cell-4' exited; see "
                    "/home/cmux/.cmux/peer-links/pi-cell-4.log\n")

    def both(argv, timeout=None, cap=0):
        if "ls" in argv:
            return mod.Ran(argv, rc=0, stdout="pi-cell-4  vm-ce2c  running  reachable\n")
        return mod.Ran(argv, rc=124, stderr=refusal_text, timed_out=True)

    monkeypatch.setenv("ORCH_MCP_CMUX", "/usr/bin/true")
    monkeypatch.setattr(mod, "run", both)
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-4", "argv": ["uname"]})
    assert is_err is True and payload["outcome"] == "CHANNEL-REFUSED", payload
    assert payload["channel_refused"] == "link-refused" and payload["timed_out"] is True, payload
    assert "timed_out and truncated are CHANNEL facts" in payload["channel_only"], payload
    assert "never the command's verdict" in payload["channel_only"], payload
    # (6b) …AND `refusal` CARRIES THE MATCHED LINE, not the first line of the buffer. The pre-fix field
    #      was `text.strip().splitlines()[0]`, so any warning the transport printed first occupied the
    #      field named for the refusal while the refusal sentence was dropped.
    assert payload["refusal"].startswith("cmux: link to 'pi-cell-4' exited"), payload


def test_T_run_is_bounded_in_MEMORY_and_TIME_not_just_in_what_it_returns(monkeypatch):
    """⛔ `cap` USED TO BOUND THE RETURN VALUE AND NOT THE BUFFERED STREAM.

    `run()` used `subprocess.run(stdout=PIPE)`, which reads the WHOLE stream into memory and
    truncates afterwards — so `box.exec {"argv": ["cat", "/dev/zero"]}` buffered without limit until
    the OOM killer took the MCP server (i.e. the entire tool surface for that session), from a
    READ-ONLY, allowlisted command. Measured with this module's own `run()`: one 128 MB stream took
    peak RSS from 71.6 MB to 282.9 MB while returning 100 bytes. `timeout_s` was unbounded too
    (`int(args.get("timeout_s") or 60)`, no maximum in the schema), so it was unbounded in TIME.

    Peak RSS is not asserted here (it is not portable in CI); what IS asserted is the two bounds the
    defect violated: the return is capped AND the call TERMINATES. Post-fix measurement for the
    record: peak RSS held at 21.2 MB across every case below.
    """
    mod = server_mod(monkeypatch)
    # (a) AN ENDLESS PRODUCER: bounded by the TIMEOUT, not by RAM, and capped.
    r = mod.run(["cat", "/dev/zero"], timeout=1, cap=64)
    assert r.timed_out is True, r.to_dict()
    assert len(r.stdout) <= 64, "the cap bounds the return; got %d" % len(r.stdout)
    assert r.truncated is True, r.to_dict()
    assert r.seconds < 30, "it must not hang past its timeout; took %.1fs" % r.seconds
    # (b) A LARGE FINITE PRODUCER: capped, truncated, and rc is still the child's own.
    r = mod.run(["bash", "-c", "yes A | head -c 5000000"], timeout=60, cap=1000)
    assert r.rc == 0, r.to_dict()
    assert len(r.stdout) == 1000, "the return is capped exactly; got %d" % len(r.stdout)
    assert r.truncated is True, r.to_dict()
    # (c) A NORMAL COMMAND IS UNCHANGED — the bound must not break the ordinary case.
    r = mod.run(["echo", "hello"], timeout=5)
    assert r.ok() and r.stdout == "hello\n", r.to_dict()
    # (d) BOTH LIMITS ARE CLAMPED, never trusted from a tool argument.
    assert mod.MAX_TIMEOUT_S > 0 and mod.MAX_CAP > 0
    r = mod.run(["echo", "x"], timeout=10 ** 9, cap=10 ** 12)
    assert r.ok(), "an absurd but harmless limit must be clamped, not refused: %r" % (r.to_dict(),)
    # ⛔ AND A DEGENERATE VALUE FALLS BACK TO THE DEFAULT, NEVER TO THE MAXIMUM. `cap < 0` was mapped
    # to `MAX_CAP`, i.e. a nonsense-low request produced the LARGEST buffer — the wrong direction for
    # the very bound this fix imposes.
    assert mod.run(["echo", "x"], timeout=-5).ok(), "a negative timeout is the default, not a refusal"
    assert len(mod.run(["echo", "x"], cap=-1).stdout) == len("x\n"), "a negative cap is the default"


def test_T_the_clamp_never_rewrites_a_declared_call_site():
    """⛔ THE MAXIMUM MUST COVER THE LARGEST DECLARED CALL SITE, OR IT SILENTLY REWRITES IT.

    `pr_state` asks for `timeout=400.0` (the whole-board `gh` read). A `MAX_TIMEOUT_S` of 300 turned
    a slow-but-legitimate read into a FALSE `UNMEASURED(... timeout after 300s)` — the exact failure
    class (#3382 invariant 1: unknown is not zero) this PR exists to remove, introduced by its own
    bound. Two declarations contradicted each other and nothing tested it, so this arm parses the
    module's own call sites and reds if any declares more than the clamp allows.
    """
    import re
    src = open(_SERVER, encoding="utf-8").read()
    mod = _load(_SERVER, "orchestrator_mcp_limits")
    timeouts = [float(x) for x in re.findall(r"\btimeout=([0-9]+(?:\.[0-9]+)?)\b", src)]
    caps = [int(x) for x in re.findall(r"\bcap=([0-9]+)\b", src)]
    assert timeouts, "the scan found no timeout= literals — the regex has drifted"
    assert max(timeouts) <= mod.MAX_TIMEOUT_S, (
        "a call site declares timeout=%s but MAX_TIMEOUT_S=%s, so the clamp silently shortens it "
        "(a slow-but-legitimate read becomes a false UNMEASURED)" % (max(timeouts), mod.MAX_TIMEOUT_S))
    # ⛔ AND THE SCAN MUST SEE THE FORM IT COULD NOT — AND MUST READ CODE, NOT PROSE. `box.exec` asks
    # for `timeout_s + CHANNEL_MARGIN_S` DELIBERATELY (see CHANNEL_MARGIN_S), so the literal-only
    # regex above skipped the one site that exceeds the caller's clamp by design, and this arm (whose
    # whole job is "no declared call site may be silently rewritten") passed over the site where that
    # was happening.
    # ⛔ THE FIRST VERSION OF THIS ARM WAS ITSELF A FALSE PASS. It matched `timeout=timeout_s + 30` in
    # a COMMENT — the regex required an integer literal and the real site names a constant — so it
    # went GREEN when the margin was deleted from the call site and RED when only the comment was
    # reworded. Comments are stripped, the identifier form is matched, and the named constant is
    # RESOLVED against the module, so the assertion is about the executed call site.
    code = "\n".join(ln for ln in src.splitlines() if not ln.lstrip().startswith("#"))
    computed = re.findall(r"\btimeout=timeout_s\s*\+\s*([A-Za-z_][A-Za-z0-9_]*|[0-9]+)\b", code)
    assert computed, ("no `timeout=timeout_s + <margin>` CALL SITE — the channel margin was dropped "
                      "from the one place it is applied (or the regex has drifted)")
    resolved = []
    for token in computed:
        if token.isdigit():
            resolved.append(int(token))
        else:
            assert hasattr(mod, token), (
                "the call site names %r, which this module does not define — the margin is no longer "
                "the constant the bound is computed from" % (token,))
            resolved.append(int(getattr(mod, token)))
    assert mod.MAX_CHANNEL_TIMEOUT_S == mod.MAX_TIMEOUT_S + mod.CHANNEL_MARGIN_S
    assert max(resolved) == mod.CHANNEL_MARGIN_S, (
        "the call site asks for +%s but CHANNEL_MARGIN_S=%s — the bound covers the larger of the two, "
        "so the smaller one silently loses the margin it declares" % (max(resolved),
                                                                    mod.CHANNEL_MARGIN_S))
    assert mod.MAX_TIMEOUT_S + max(resolved) <= mod.MAX_CHANNEL_TIMEOUT_S, (
        "a computed call site asks for <clamp>+%s but MAX_CHANNEL_TIMEOUT_S=%s, so the clamp still "
        "rewrites it and the transport's own answer is discarded as CHANNEL-TIMEOUT"
        % (max(resolved), mod.MAX_CHANNEL_TIMEOUT_S))
    assert max(caps) <= mod.MAX_CAP, (
        "a call site declares cap=%s but MAX_CAP=%s" % (max(caps), mod.MAX_CAP))


def test_T_the_cap_bounds_ALLOCATION_not_only_the_return(monkeypatch):
    """⛔ THE PREVIOUS ARM COULD NOT FAIL. It asserted the two properties the OLD code already had —
    the return was already capped (`_decode(exc.stdout, cap)`) and the call already terminated
    (`timeout=`) — so reverting the whole fix left it green (verified: the pre-fix `subprocess.run`
    body passed it). `tracemalloc` makes the actual regression observable and portable, and it
    discriminates by ~8,500x: peak 0.2 MB fixed vs 1,709.4 MB reverted, same `cap=64`,
    `cat /dev/zero`, `timeout=1`.
    """
    import tracemalloc
    mod = server_mod(monkeypatch)
    tracemalloc.start()
    try:
        tracemalloc.reset_peak()
        mod.run(["cat", "/dev/zero"], timeout=1, cap=64)
        _, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()
    assert peak < 5_000_000, (
        "`cap` must bound ALLOCATION, not only the return — an endless producer buffered %.1f MB "
        "while returning 64 bytes, which is how `box.exec` OOMed the server" % (peak / 1e6))


def test_T_lane_dispatch_maps_exits_and_the_two_measured_silent_actuators(tmp_path, monkeypatch):
    mod = server_mod(monkeypatch)
    brief = tmp_path / "brief.md"
    brief.write_text("# brief\n")
    wt = tmp_path / "wt"
    wt.mkdir()
    subprocess.run(["git", "-C", str(wt), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(wt), "commit", "-q", "--allow-empty", "-m", "x"],
                   check=True, env=dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                                        GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t"))
    o = tmp_path / "o"
    (o / "bg").mkdir(parents=True)
    monkeypatch.setenv("O", str(o))

    # (a) a launcher that exits 0 and writes NO pid — the measured `launcher did not report a pid: ''`
    monkeypatch.setenv("ORCH_MCP_DISPATCH", stub(tmp_path, "d0.sh", "print('')"))
    is_err, payload = one(mod, "lane.dispatch", {"name": "L1", "worktree": str(wt),
                                                 "brief": str(brief)})
    assert is_err and payload["refused"] == "no-pid", payload

    # (b) …and with a pid file it is a result
    (o / "bg" / "L2.pid").write_text("4321\n")
    is_err, payload = one(mod, "lane.dispatch", {"name": "L2", "worktree": str(wt),
                                                 "brief": str(brief)})
    assert is_err is False and payload["pid"] == 4321

    # (c) brief-gate refusal 80 — the EXISTING vocabulary, not a new one
    monkeypatch.setenv("ORCH_MCP_DISPATCH", stub(tmp_path, "d80.sh", "print('refused')", code=80))
    is_err, payload = one(mod, "lane.dispatch", {"name": "L3", "worktree": str(wt),
                                                 "brief": str(brief)})
    assert is_err and payload["refused"] == "brief-refused"
    assert payload["refusal_vocabulary"]["80"] == "brief-refused"
    # 73 and 75 must not collapse
    assert payload["refusal_vocabulary"]["73"] != payload["refusal_vocabulary"]["75"]

    # (d) the OTHER measured silent actuator: a branch that already exists
    subprocess.run(["git", "-C", str(wt), "branch", "p0-10000"], check=True)
    is_err, payload = one(mod, "lane.dispatch", {"name": "L4", "worktree": str(wt),
                                                 "brief": str(brief), "branch": "p0-10000"})
    assert is_err and payload["refused"] == "branch-exists", payload

    # (e) `env` has NO implementation in the launcher → declared, never silently dropped
    is_err, payload = one(mod, "lane.dispatch", {"name": "L5", "worktree": str(wt),
                                                 "brief": str(brief), "env": {"K": "V"}})
    assert is_err and "UNSUPPORTED(env" in payload["env"]


def test_T_reminder_is_file_backed_and_survives_a_restart(tmp_path, monkeypatch):
    mod = server_mod(monkeypatch)
    state = tmp_path / "state"
    monkeypatch.setenv("ORCH_MCP_STATE_DIR", str(state))
    is_err, payload = one(mod, "fleet.reminder", {"action": "set", "id": "r1",
                                                  "message": "check the queue", "due_at": 1})
    assert is_err is False and (state / "reminders.json").exists()
    is_err, payload = one(mod, "fleet.reminder", {"action": "list"})
    assert is_err is False and payload["reminders"]["r1"]["message"] == "check the queue"
    assert payload["reminders"]["r1"]["delivery"] == "turn-boundary"
    # a NEW server process reads the same queue — that is "survives a session restart"
    fresh = _load(_SERVER, "orchestrator_mcp_fresh")
    is_err, payload = one(fresh, "fleet.reminder", {"action": "list"})
    assert "r1" in payload["reminders"]
    is_err, payload = one(mod, "fleet.reminder", {"action": "cancel", "id": "r1"})
    assert is_err is False and payload["cancelled"]["id"] == "r1"
    is_err, payload = one(mod, "fleet.reminder", {"action": "cancel", "id": "r1"})
    assert is_err and payload["refused"] == "no-such-reminder"
    # an unreadable queue is NOT an empty queue
    (state / "reminders.json").write_text("{not json")
    is_err, payload = one(mod, "fleet.reminder", {"action": "list"})
    assert is_err and "UNMEASURED(" in payload["reminders"]


def test_T_beat_checkpoint_reads_the_loop_safe_report_and_the_cycle_verdict(tmp_path, monkeypatch):
    mod = server_mod(monkeypatch)
    monkeypatch.setenv("ORCH_MCP_REPORT", stub(tmp_path, "rep.sh", "print('report body')"))
    o = tmp_path / "o"
    o.mkdir()
    is_err, payload = one(mod, "fleet.beat_checkpoint", {"action": "read", "hours": 6, "o": str(o)})
    assert payload["report"]["outcome"] == "READ"
    assert payload["report"]["source"].startswith("report.sh (loop-safe)")
    # no records at all is ABSENT — never HEALTHY
    assert payload["cycle_verdict"]["outcome"] in ("NO-ANSWER", "DEGRADED", "UNMEASURED"), payload
    assert is_err is True
    is_err, payload = one(mod, "fleet.beat_checkpoint", {"action": "nope"})
    assert is_err and payload["refused"] == "unknown-action"
    assert payload["allowed"] == ["read", "write"]


def test_T_read_only_mode_refuses_every_mutating_tool(tmp_path, monkeypatch):
    """The §13 Q5 seam: one switch, and every mutating tool refuses with a TYPED refusal."""
    monkeypatch.setenv("ORCH_MCP_READ_ONLY", "1")
    mod = server_mod(monkeypatch)
    for name, args in (("lane.dispatch", {"name": "L", "worktree": "/tmp", "brief": "/tmp/x"}),
                       ("box.exec", {"box": "b", "argv": ["uname"]}),
                       ("fleet.reminder", {"action": "set", "message": "m"}),
                       ("fleet.beat_checkpoint", {"action": "write", "state": {"a": "b"}})):
        is_err, payload = one(mod, name, args)
        assert is_err and payload["refused"] == "read-only", (name, payload)


def test_T_the_registry_is_read_only_across_the_whole_surface(env):
    """S10: a session over the registry-touching READ tools leaves the registry's refs byte-identical.

    ⛔ NOT "over EVERY tool", which is what this said: the session below drives `tools/list` plus the
    two registry reads. The MUTATING names are covered by the read-only arm above, which requires each
    of them to be REFUSED before it touches anything — not by this comparison. A docstring that claims
    a wider scope than the body executes is the false-coverage class this suite exists to red.
    """
    mod_reg, origin, _repo, _tmp = env
    monkeypatch = pytest.MonkeyPatch()
    try:
        mod = server_mod(monkeypatch)
        before = subprocess.run(["git", "ls-remote", str(origin)], capture_output=True, text=True,
                                check=True).stdout
        rpc(mod_reg, [{"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                      {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                       "params": {"name": "lane.artifact", "arguments": {"lane": "X"}}},
                      {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                       "params": {"name": "pr.queue", "arguments": {"repo": "o/r"}}}], mod=mod)
        after = subprocess.run(["git", "ls-remote", str(origin)], capture_output=True, text=True,
                               check=True).stdout
        assert before == after
    finally:
        monkeypatch.undo()


# ── the saved-work axis of `claim.check` (owner comment 6662755371 on #3382) ──────────────────
# Two tests, each named for the failure it prevents. 222 snapshots of half-finished work sat on
# origin under `refs/wip/*` with nothing pointing at them, so an agent asked "is this claimed?",
# was told `free`, and redid work somebody had already done. The lookup is the fix; the second
# test is that the lookup can never lie by omission.


def _saved_mod():
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("orch_srv_saved", os.path.join(here, "server.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_T_saved_work_is_found_by_slug_token(tmp_path):
    """A snapshot named after the issue is REPORTED — this is the lookup that did not exist.

    Without it `claim.check` answered "unclaimed" while the work sat in `refs/wip/<slug>`, which is
    how the same task got done twice in six worktrees.
    """
    import subprocess
    origin = tmp_path / "origin.git"
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
    work = tmp_path / "work"
    subprocess.run(["git", "clone", "-q", str(origin), str(work)], check=True)
    git = lambda *a: subprocess.run(["git", "-C", str(work), *a], check=True,
                                    capture_output=True, text=True)
    subprocess.run(["git", "-C", str(work), "config", "user.email", "t@t"], check=True)
    subprocess.run(["git", "-C", str(work), "config", "user.name", "t"], check=True)
    (work / "half.sh").write_text("echo half\n")
    git("add", "half.sh")
    git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "half-finished work")
    git("push", "-q", "origin", "HEAD:refs/wip/ai-9001")

    mod = _saved_mod()
    got = mod._saved_for_issue(str(work), 9001)
    assert got["count"] == 1, got
    assert not got.get("unmeasured"), got
    entry = got["matches"][0]
    assert entry["ref"] == "refs/wip/ai-9001", entry
    assert entry["age"] and "UNMEASURED" not in str(entry["age"]), entry
    assert entry["file_count"] == 1, entry
    # the coverage caveat travels with the answer: `none` must never read as "no work was in progress"
    assert got["save_coverage"] == "normal-exit-only", got
    # ⛔ AND THE READ MUST NOT WRITE THE CALLER'S CHECKOUT. It used to `git fetch` into
    # `refs/wip-remote/<slug>` INSIDE `work` — a repo mutation by a tool declared `readOnlyHint: true`
    # that `--read-only` could not refuse. Asserted on the refs, not on the code path.
    refs = subprocess.run(["git", "-C", str(work), "for-each-ref", "--format=%(refname)"],
                          check=True, capture_output=True, text=True).stdout
    assert "refs/wip-remote" not in refs, ("the saved-work read wrote the caller's checkout: %s" % refs)

    # a slug that is NOT the token must not match: `ai-90010` is a different item
    other = mod._saved_for_issue(str(work), 90010)
    assert other["count"] == 0, other
    assert other["none_means"].startswith("no snapshot was found"), other


def test_T_saved_work_counts_a_MERGE_snapshot(tmp_path):
    """⛔ THE SECOND RESCUE IS A MERGE COMMIT, AND `diff-tree` PRINTS NOTHING FOR A MERGE.

    `bg-rescue-wip.sh` commits a snapshot with `-p HEAD -p <previous snapshot>`, so the FIRST rescue is
    a single parent and every LATER one — the grace-period work, the snapshot that matters most — is a
    MERGE. `git diff-tree` emits no patch for a merge unless `-m` is passed, and exits 0, so the code
    took the MEASURED branch and published `file_count: 0` with `files: []` — invariant 1's exact
    failure (unknown reported as zero) for the wrong shape, and invisibly: the single-parent arm above
    cannot see it. Measured on real origin data (`refs/wip-remote/fix-3377-mandate-preflight` has two
    parents: `--name-only` against `^1` lists 1 file, `diff-tree` without `-m` lists none).
    """
    import subprocess
    origin = tmp_path / "origin.git"
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
    work = tmp_path / "work"
    subprocess.run(["git", "clone", "-q", str(origin), str(work)], check=True)

    def git(*a, **kw):
        return subprocess.run(["git", "-C", str(work), *a], check=True, capture_output=True,
                              text=True, **kw)

    git("config", "user.email", "t@t")
    git("config", "user.name", "t")
    (work / "one.sh").write_text("echo one\n")
    git("add", "one.sh")
    git("commit", "-q", "-m", "first rescue")
    first = git("rev-parse", "HEAD").stdout.strip()
    git("push", "-q", "origin", "HEAD:refs/wip/ai-9002")
    # the SECOND rescue: two parents, so it is a merge commit
    git("checkout", "-q", "-b", "second", first)
    (work / "two.sh").write_text("echo two\n")
    git("add", "two.sh")
    git("commit", "-q", "-m", "second rescue")
    second = git("rev-parse", "HEAD").stdout.strip()
    merged = git("commit-tree", second + "^{tree}", "-p", second, "-p", first,
                 "-m", "rescue merge").stdout.strip()
    parents = [ln for ln in git("cat-file", "-p", merged).stdout.split("\n\n")[0].splitlines()
               if ln.startswith("parent ")]
    assert len(parents) == 2, ("the fixture is not a two-parent commit: %r" % (parents,))
    git("push", "-q", "origin", "%s:refs/wip/ai-9002" % merged)

    mod = _saved_mod()
    got = mod._saved_for_issue(str(work), 9002)
    assert got["count"] == 1, got
    entry = got["matches"][0]
    assert entry["file_count"] is not None, (
        "the merge snapshot's file count is UNMEASURED rather than measured: %r" % (entry,))
    assert entry["file_count"] > 0, (
        "a MERGE snapshot published file_count 0 — `diff-tree` needs `-m` for a merge, or the "
        "count is a false zero on exactly the snapshot that matters most: %r" % (entry,))


def test_T_saved_work_reads_a_RELATIVE_origin_without_writing_the_checkout(tmp_path):
    """⛔ THE READ-ONLY FIX MUST NOT CHANGE THE ANSWER. A RELATIVE remote (`../origin.git`) is resolved
    by git against the process cwd, so fetching it from the scratch dir looks in the wrong place and
    turns a previously-measured snapshot into UNMEASURED — the safety fix buying itself with a
    behaviour change. The URL is absolutised against the caller's checkout, and the checkout still
    ends the call with the refs it started with.
    """
    import subprocess
    origin = tmp_path / "origin.git"
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
    work = tmp_path / "work"
    subprocess.run(["git", "clone", "-q", str(origin), str(work)], check=True)
    git = lambda *a: subprocess.run(["git", "-C", str(work), *a], check=True, capture_output=True,
                                    text=True)
    git("config", "user.email", "t@t")
    git("config", "user.name", "t")
    (work / "a.sh").write_text("echo a\n")
    git("add", "a.sh")
    git("commit", "-q", "-m", "work")
    git("push", "-q", "origin", "HEAD:refs/wip/ai-9001")
    git("remote", "set-url", "origin", "../origin.git")     # RELATIVE, as measured in review

    mod = _saved_mod()
    got = mod._saved_for_issue(str(work), 9001)
    assert got["count"] == 1, got
    entry = got["matches"][0]
    assert entry["file_count"] == 1, entry
    assert "UNMEASURED" not in str(entry["age"]), entry
    refs = subprocess.run(["git", "-C", str(work), "for-each-ref", "--format=%(refname)"],
                          check=True, capture_output=True, text=True).stdout
    assert "refs/wip-remote" not in refs, refs

    # ⛔ AND THE `repo` ARGUMENT ITSELF MAY BE RELATIVE — `claim.check` hands it straight to `git -C`.
    # `os.path.normpath(join(repo, url))` is only absolute when `repo` is, so with `repo='.'` the join
    # stayed RELATIVE and the fetch ran from the server's scratch dir: the same UNMEASURED regression,
    # in the one case that could silently read a DIFFERENT repository. Nothing tested it — the arm
    # above passes an absolute path, where both implementations agree.
    cwd = os.getcwd()
    try:
        os.chdir(str(work))
        rel = mod._saved_for_issue(".", 9001)
    finally:
        os.chdir(cwd)
    assert rel["count"] == 1, rel
    rel_entry = rel["matches"][0]
    assert rel_entry["file_count"] == 1, rel_entry
    assert "UNMEASURED" not in str(rel_entry["age"]), rel_entry


def test_T_saved_work_unreadable_is_unmeasured_never_none(tmp_path):
    """An unreadable registry is `UNMEASURED`, never `none` — invariant 1 on the saved axis.

    The empty-set-is-not-absence rule is the whole reason this axis exists: reporting `none` when
    the read failed is the same lie as reporting `unclaimed` when nothing was consulted.
    """
    mod = _saved_mod()
    got = mod._saved_for_issue(str(tmp_path / "not-a-checkout"), 3382)
    assert got["count"] is None, got
    assert str(got["unmeasured"]).startswith("UNMEASURED("), got
    assert "not a directory" in got["unmeasured"], got
    # and it still carries the caveat, so a caller cannot read the absence as evidence
    assert got["save_coverage"] == "normal-exit-only", got


def test_T_box_exec_refuses_a_checkout_whose_config_names_a_program(tmp_path, monkeypatch):
    """⛔ THE CLASS THAT CANNOT BE PINNED, SO IT IS REFUSED INSTEAD.

    `filter.<driver>.clean` runs for `status` on any dirty path whose `.gitattributes` names the
    driver — `status` is the ONLY admitted verb that reaches it (the `diff` half of this class is gone
    with the verb boundary). Measured: a plain `git status` in a repo with `filter.evil.clean` executes
    it, and its STDOUT becomes the blob content (so it can also forge what the verb reports).
    `merge.<driver>.driver` is a MERGE driver whose only route in was `show --remerge-diff` — and
    `show` is not an admitted verb any more, so that route is closed at the verb boundary; the key stays
    unpinnable (its NAME comes from the checkout) and refusing it remains correct either way. Their KEY
    NAMES come from the checkout, so no `-c` pin can address
    them. And a PARTIAL CLONE turns an object read into a LAZY FETCH, which runs the repo's transport
    program (`core.sshCommand`, `remote.<name>.proxy`, or an `ext::<program>` URL that survives pinning
    the helpers).

    So the exec reads the TARGET checkout's own config and refuses, naming the key. The cmux stub below
    answers the pre-check with a config file and every other invocation with `ok`, so the test drives
    the real code path rather than stubbing the check itself.
    """
    mod = server_mod(monkeypatch)
    cfg = tmp_path / "gitconfig.txt"
    argv_log = tmp_path / "argv.log"
    # the stub echoes a REAL `git config --includes --list -z` listing: NUL-separated records, key and
    # value separated by a NEWLINE — so a key containing `=` is exercised for real
    cmux = stub(tmp_path, "cmux_cfg.sh",
                "import sys, os\n"
                "args = sys.argv[1:]\n"
                "if 'config' in args:\n"
                "    open(os.environ['FAKE_ARGV_LOG'], 'a').write(' '.join(args) + '\\n')\n"
                "    sys.stdout.write(open(os.environ['FAKE_GIT_CONFIG']).read())\n"
                "else:\n"
                "    print('ok')\n")
    monkeypatch.setenv("ORCH_MCP_CMUX", cmux)
    monkeypatch.setenv("FAKE_GIT_CONFIG", str(cfg))
    monkeypatch.setenv("FAKE_ARGV_LOG", str(argv_log))

    # ⛔ THE REAL SHAPES. A plain checkout prints a RELATIVE origin (`file:.git/config`, measured on git
    # 2.43 from the root, a subdirectory and via `git -C <abs>`); only a linked worktree prints an
    # absolute `.git/worktrees/<n>/config`. A fixture that used neither certified nothing.
    REPO_ORIGIN = "file:.git/config"
    WORKTREE_ORIGIN = "file:/box/repo/.git/worktrees/lane/config.worktree"
    GLOBAL_ORIGIN = "file:/box/.gitconfig"

    def z(*records, origin=REPO_ORIGIN):
        """Render a REAL `git config --includes --list -z --show-origin` listing.

        The shape is `ORIGIN \0 KEY\nVALUE \0 ORIGIN \0 …` (verified against git 2.43). A bare string
        is a VALUELESS key (git prints just the key) and a tuple is (key, value); the distinction
        matters because a key may itself contain `=`, which is why the parser must not split on it.
        `origin` is how the pre-check tells a checkout's own config from a global one without a
        second exec.
        """
        out = []
        for rec in records:
            key, value = rec if isinstance(rec, tuple) else (rec, None)
            out.append("%s\0%s%s\0" % (origin, key, "" if value is None else "\n%s" % value))
        return "".join(out)

    for config, needle in ((z(("user.email", "a@b"), ("filter.evil.clean", "/tmp/x.sh")),
                            "filter.evil.clean"),
                           (z(("filter.lfs.process", "git-lfs filter-process")), "filter.lfs.process"),
                           (z(("merge.md.driver", "/tmp/m.sh %O %A %B")), "merge.md.driver"),
                           (z(("extensions.partialClone", "origin")), "PARTIAL CLONE"),
                           # ⛔ `extensions.partialClone` IS A REMOTE NAME, NOT A BOOLEAN: a promisor
                           # remote literally named `false`/`off` passed the shared false-set while
                           # git happily fetched from it. Presence alone must refuse.
                           (z(("extensions.partialClone", "false")), "PARTIAL CLONE"),
                           (z(("extensions.partialClone", "off")), "PARTIAL CLONE"),
                           (z(("remote.origin.promisor", "true")), "PROMISOR"),
                           # ⛔ A VALUELESS ENTRY IS `true` IN GIT and must refuse; a subsection
                           # containing `=` must not hide the key from the parser.
                           (z("remote.origin.promisor"), "PROMISOR"),
                           # ⛔ `remote.<name>.uploadpack` IS A PROGRAM on the fetch path
                           (z(("remote.origin.uploadpack", "/tmp/mark.sh")), "uploadpack"),
                           (z(("filter.a=b.clean", "/tmp/x.sh")), "filter.a=b.clean"),
                           (z(("merge.a=b.driver", "/tmp/m.sh")), "merge.a=b.driver")):
        cfg.write_text(config)
        is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["git", "status"]})
        assert is_err, (config, payload)
        assert payload["refused"] == "repo-config-names-a-program", (config, payload)
        assert needle in payload["reason"], (config, payload)

    # the listing is read in the scopes the VERB reads (no `--local`), NUL-separated, with includes
    assert argv_log.exists(), "the pre-check never ran"
    precheck = argv_log.read_text().strip().splitlines()[-1].split()
    assert "--includes" in precheck and "-z" in precheck, precheck
    assert "--local" not in precheck, ("the pre-check must read the EFFECTIVE config: `--local` misses "
                                        "`.git/config.worktree` and the global scope, which the verb "
                                        "does read: %r" % (precheck,))

    # a config that names NO program is fine, and the exec runs — with the pre-check REPORTED, so the
    # caller can tell a clean pre-check from one that never ran. `core.repositoryformatversion` is NOT
    # evidence any more (the arm was deleted in round 10): these fixtures are `clean` because their
    # origin is `file:.git/config`, which is the origin-shape rule — the key is decorative here.
    for config in (z(("core.repositoryformatversion", "0"), ("user.email", "a@b")),
                   z(("core.repositoryformatversion", "0"), ("core.pager", "less")),
                   z(("core.repositoryformatversion", "0"), ("remote.origin.promisor", "false")),
                   z(("core.repositoryformatversion", "0"), ("remote.origin.promisor", "off"))):
        cfg.write_text(config)
        is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["git", "status"]})
        assert payload.get("refused") is None, (config, payload)
        assert payload["rc"] == 0, (config, payload)
        assert payload["repo_config"] == "clean", (config, payload)

    # ⛔ AND A LISTING THAT DID NOT FIT IS A REFUSAL, NOT A CLEAN ONE. The driver here sits past
    # `MAX_CAP`; `run()` truncates and DISCARDS the remainder, so a check that trusted its output would
    # report `clean` on a config it never finished reading (measured at byte 468123 by review).
    cfg.write_text(z(("fill.k", "y" * 2_100_000), ("filter.evil.clean", "/tmp/x.sh")))
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["git", "status"]})
    assert payload.get("refused") == "repo-config-names-a-program", payload
    assert "CUT SHORT" in payload["reason"], payload

    # ⛔ NEITHER DOES A TIMEOUT FALL THROUGH TO THE EXEC. `run()` returns rc=None on a timeout, and the
    # pre-check's budget is SMALLER than the exec's — so a slow config is exactly the case that can
    # lose the pre-check and still finish the verb. Driven directly: the real function against a
    # timed-out read whose stdout ALREADY holds a dangerous key.
    real_run = mod.run
    try:
        mod.run = lambda *a, **kw: mod.Ran(
            ["git"], rc=None, timed_out=True,
            stdout=z(("core.repositoryformatversion", "0"),
                     ("filter.evil.clean", "/tmp/x.sh")))
        fault, measured = mod._repo_config_fault("cmux", "box", 60)
        assert "filter.evil.clean" in fault, fault          # the drained stdout is PARSED, not discarded
        assert measured is True
        mod.run = lambda *a, **kw: mod.Ran(["git"], rc=None, error="OSError: boom")
        fault, measured = mod._repo_config_fault("cmux", "box", 60)
        assert fault and "could not be READ" in fault, fault
        # ⛔ AND A TIMEOUT OVER A **CLEAN** LISTING STILL REFUSES. `run()` reports its own kill as
        # `rc=None`, so the `rc != 0` clause is what fires here — `timed_out` needs no separate term,
        # and claiming it did was a comment about a distinction the fixture cannot make.
        mod.run = lambda *a, **kw: mod.Ran(
            ["git"], rc=None, timed_out=True,
            stdout=z(("core.repositoryformatversion", "0")))
        fault, measured = mod._repo_config_fault("cmux", "box", 60)
        assert fault and "could not be READ" in fault, fault
        # ⛔ AND THE TRANSPORT'S OWN TIMEOUT IS rc 124, NOT `timed_out` — with the shared budget it can
        # no longer answer first, but if it does, a non-zero status must still refuse rather than
        # report `unmeasured` and run the verb.
        mod.run = lambda *a, **kw: mod.Ran(
            ["git"], rc=124, stderr="cmux: operation timed out after 60s",
            stdout=z(("core.repositoryformatversion", "0")))
        fault, measured = mod._repo_config_fault("cmux", "box", 60)
        assert fault and "could not be READ" in fault, fault
    finally:
        mod.run = real_run

    # ⛔ AND `rc 0` OUTSIDE A REPO IS NOT `clean`. Without `--local`, `git config --list` SUCCEEDS
    # outside a checkout (global+system scope only), so "no checkout" would report `clean` — the
    # conflation the tri-state exists to end. The signal is the ORIGIN SHAPE — the listing's origin is
    # the global config, not a `.git/config` — and NOT the absence of `core.repositoryformatversion`
    # (that arm was deleted in round 10; the arm immediately below proves a version-key-less checkout
    # reads `clean` from its origin).
    cfg.write_text(z(("user.email", "a@b"), ("core.pager", "less"), origin=GLOBAL_ORIGIN))
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["git", "status"]})
    assert payload.get("refused") is None, payload
    assert payload["repo_config"] == "unmeasured", payload

    # ⛔ BUT A CHECKOUT WHOSE `core.repositoryformatversion` WAS UNSET IS STILL A CHECKOUT. Deciding
    # repo presence from that ONE optional key mislabelled a real repo `unmeasured` forever — a false
    # "the check did not run" for a config that was read and clean. An origin under `/` `.git/` is now
    # the ONLY piece of evidence — the format-key arm was deleted in round 10, so there is no first
    # piece for this to be "second" to.
    for origin in (REPO_ORIGIN, WORKTREE_ORIGIN):
        cfg.write_text(z(("user.email", "a@b"), origin=origin))   # a checkout, no version key
        is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["git", "status"]})
        assert payload.get("refused") is None, (origin, payload)
        assert payload["repo_config"] == "clean", (origin, payload)

    # ⛔ AND FOREIGN BYTES AT THE HEAD OF THE STREAM CANNOT DESYNC THE SCAN. This repo documents that
    # the transport can prefix payload bytes (a banner line that drifted between cmux builds); a
    # POSITIONAL origin/record pairing would shift by one on a NUL-terminated banner, read every record
    # as an origin, match no anchored key and report the poisoned repo CLEAN. The pairing is by token
    # SHAPE now, so a banner is neither an origin nor a matchable key and the fault is still found.
    cfg.write_text("warning: cmux 0.1.1 available\0" + z(("filter.evil.clean", "/tmp/x.sh")))
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["git", "status"]})
    assert payload.get("refused") == "repo-config-names-a-program", payload
    assert "filter.evil.clean" in payload["reason"], payload

    # a NON-git program never pays the pre-check — asserted on the REAL argv log (the cmux stub above is
    # still installed: it logs every `config` invocation), not on its stdout.
    before = len(argv_log.read_text().splitlines()) if argv_log.exists() else 0
    is_err, payload = one(mod, "box.exec", {"box": "pi-cell-1", "argv": ["ls", "-l"]})
    assert payload.get("refused") is None, payload
    after = len(argv_log.read_text().splitlines()) if argv_log.exists() else 0
    assert after == before, ("a NON-git program paid the git pre-check: %r"
                             % (argv_log.read_text(),))


def test_T_box_exec_disables_the_program_git_config_can_name():
    """[P1, review] BEFORE THE VERB BOUNDARY, a fully-allowlisted `git diff` ran `diff.external` FROM CONFIG.

    Measured before this fix: with `diff.external` set (or `GIT_EXTERNAL_DIFF` in the env), argv
    `["git","diff"]` — every element allowlisted — spawned that program. The program allowlist bounded
    the program and the argv bounded the flags; configuration escaped both, the same class as the
    `--output` write the surface already refuses. `cmux vm exec` forwards no environment, so the
    guarantee has to travel inside the argv — and it must come LAST, because git honours the last
    occurrence of a flag and a caller-supplied `--ext-diff` would otherwise re-enable the hook.
    """
    mod = _saved_mod()
    # ⛔ THE CONFIG CLASS, NOT ONE KEY. Every repo-config key that NAMES A PROGRAM and is reachable by a
    # READ verb is pinned in the same global slot; `gpg.program` and `core.alternateRefsCommand` were
    # both measured executing on an allowlisted argv, one of them with NO flag at all
    # (`log.showSignature=true` + `gpg.program` make a plain `git show` run it).
    for key in ("core.fsmonitor=", "core.alternateRefsCommand=", "log.showSignature=false",
                "gpg.program=/bin/false", "core.pager=cat", "core.hooksPath=/dev/null",
                # ⛔ `gpg.program` IS THE OPENPGP VERIFIER ONLY. `gpg.<format>.program` is a SEPARATE
                # key per format (all three are listed by `git help --config`), so pinning the first
                # left x509/ssh signatures running a repo-named program — MEASURED, when `log` was
                # still an allowlisted verb, through `git log --show-signature`.
                "gpg.openpgp.program=/bin/false", "gpg.x509.program=/bin/false",
                "gpg.ssh.program=/bin/false"):
        assert key in mod.GIT_PIN_CONFIG, key
    assert mod.GIT_GLOBAL_FLAGS == ("--no-pager",), mod.GIT_GLOBAL_FLAGS
    expected_head = ["git"]
    for pin in mod.GIT_PIN_CONFIG:
        expected_head += ["-c", pin]
    expected_head += list(mod.GIT_GLOBAL_FLAGS)
    # ⛔ `diff` IS NO LONGER AN ADMITTED VERB (review cycle 3, P1 — the boundary moved from the flag to
    # the verb), and `_harden_argv` pins only admitted verbs, so a diff argv now comes back untouched.
    # That is the correct shape: the argv is refused BEFORE execution, so hardening it would only
    # matter to a future reader. The disarm contract is therefore pinned on the admitted verbs.
    assert mod._harden_argv(["git", "diff"]) == ["git", "diff"], mod._harden_argv(["git", "diff"])
    for admitted in ("status", "rev-parse", "ls-files"):
        pinned = mod._harden_argv(["git", admitted])
        assert pinned[:len(expected_head)] == expected_head, (admitted, pinned)
        assert pinned[len(expected_head):] == [admitted], pinned
    # `status` carries the pins and nothing else — it has no diff machinery to disarm
    assert mod._harden_argv(["git", "status"])[-1] == "status"
    assert "--no-ext-diff" not in mod._harden_argv(["git", "status"])
    # ⛔ THE DISARM CONTRACT IS NOW MOOT FOR THE ALLOWLISTED VERBS, AND THAT IS THE POINT (review cycle
    # 3, P1). The pair below used to be emitted for `diff`/`show`/`log`; those verbs are REFUSED at the
    # verb boundary now, because `git diff <file> <file>` reaches the same file contents with NO flag at
    # all (it implies `--no-index` outside a repo, and a cell's exec cwd is `/`). `_harden_argv`
    # therefore leaves a refused verb untouched — pinning a flag on an argv that never runs would be
    # decoration, and the earlier "two copies" assertions were pinning exactly that.
    assert mod._harden_argv(["git", "diff", "--dst-prefix"]) == ["git", "diff", "--dst-prefix"], \
        mod._harden_argv(["git", "diff", "--dst-prefix"])
    # ⛔ AND THE RE-ENABLING SPELLINGS NEVER REACH THE ARGV: the verb itself is refused, so no token
    # rule is needed. (An earlier revision refused every `--ex…` and thereby FALSE-BLOCKED the
    # bounded-search primitive `git ls-files --others --exclude-standard`, pinned allowed below.)
    for tok in ("--ext-diff", "--textconv", "--show-signature", "--remerge-diff"):
        assert mod._allowlisted(["git", "diff", tok])[0] is False, tok
    # the transport axis is pinned as defence in depth (the CONTROL is the fail-closed pre-check)
    assert "protocol.ext.allow=never" in mod.GIT_PIN_CONFIG
    assert "core.sshCommand=/bin/false" in mod.GIT_PIN_CONFIG
    # ⛔ THE ONE BOUNDED-SEARCH PRIMITIVE THAT MUST STAY ALLOWED — it is the reason a stem rule on
    # `--ex…` was reverted.
    assert mod._allowlisted(["git", "ls-files", "--others", "--exclude-standard"])[0] is True
    assert mod._allowlisted(["git", "ls-files", "--exclude=*.pyc"])[0] is True



def test_T_lane_dispatch_refuses_when_branch_existence_cannot_be_read(tmp_path, monkeypatch):
    """[P2, review] An UNREADABLE existence probe must not read as "the branch is free".

    The guard exists for a measured silent actuator (`fatal: a branch named 'p0-10000' already exists`
    reaching a caller as prose). Before this, a failed probe set `remote_exists = None` and the code fell
    through to DISPATCH — the guard disappearing exactly when it could not be evaluated, which is when a
    collision is most likely. Three-valued now, and ORDERED: a branch the LOCAL probe finds is still a
    measured `branch-exists`; only an absent local answer makes an unreadable remote a refusal.
    """
    import subprocess
    mod = _saved_mod()
    monkeypatch = pytest.MonkeyPatch()
    try:
        wt = tmp_path / "wt"
        wt.mkdir()
        subprocess.run(["git", "init", "-q", str(wt)], check=True)
        subprocess.run(["git", "-C", str(wt), "-c", "user.email=t@t", "-c", "user.name=t",
                        "commit", "-q", "--allow-empty", "-m", "x"], check=True)
        brief = tmp_path / "b.md"
        brief.write_text("x")
        monkeypatch.setenv("O", str(tmp_path / "o"))
        (tmp_path / "o" / "bg").mkdir(parents=True)
        # no `origin` here → the remote probe cannot be read, and the local branch does not exist
        is_err, payload = one(mod, "lane.dispatch", {"name": "L9", "worktree": str(wt),
                                                    "brief": str(brief), "branch": "p0-77777"})
        assert is_err and payload["refused"] == "branch-existence-unmeasured", payload
        assert "UNMEASURED(" in str(payload["remote"]), payload
        # a branch the LOCAL probe FINDS is a measured collision, not an abstention
        subprocess.run(["git", "-C", str(wt), "branch", "p0-77778"], check=True)
        is_err, payload = one(mod, "lane.dispatch", {"name": "L10", "worktree": str(wt),
                                                    "brief": str(brief), "branch": "p0-77778"})
        assert is_err and payload["refused"] == "branch-exists", payload
    finally:
        monkeypatch.undo()


def test_T_box_exec_refuses_the_read_back_escapes_cat_left_open():
    """[P1, review cycle 2] Removing `cat` did NOT close the file-read class, and nothing pinned it.

    Measured by the reviewer on the 0600 JEV key store: `["git","diff","--no-index","<file>","/dev/null"]`
    validated, hardened intact, needed no repo, and `_box_exec` returns stdout whatever the rc — so the
    whole file landed in the response. The removal of `cat` itself was UNPINNED (a grep for `"cat"` in
    this file returned nothing), which is how the class survived its own fix.
    """
    mod = _saved_mod()
    # the program is gone
    ok, why = mod._allowlisted(["cat", "/etc/shadow"])
    assert not ok and "not on the allowlist" in why, (ok, why)
    # …and its capability is gone too: an allowlisted program could still dump a named file
    for probe in (["git", "diff", "--no-index", "/etc/shadow", "/dev/null"],
                  ["git", "diff", "--no-index=/etc/shadow", "/dev/null"]):
        ok, why = mod._allowlisted(probe)
        # the refusal may name the token (flag era) or the verb (the current boundary) — both are
        # refusals, and pinning the exact wording would break the next time the boundary tightens
        assert not ok and ("--no-index" in why or "not on the allowlist" in why), (probe, ok, why)
    # ⛔ THE BOUNDARY IS THE VERB, NOT THE FLAG (review cycle 3, P1). `git diff` reached file contents
    # WITHOUT any flag — `git diff <file> <file>` implies `--no-index` when the operands are not repo
    # pathspecs, which is always true on a cell (its exec cwd is `/`). So `diff`/`show`/`log` are gone
    # from the allowlist entirely, and the legitimate forms are the METADATA verbs.
    for verb in ("diff", "show", "log"):
        ok, why = mod._allowlisted(["git", verb])
        assert not ok, (verb, ok, why)
        assert "not read-only" in why or "not on the allowlist" in why, (verb, why)
    for probe in (["git", "status"], ["git", "rev-parse", "HEAD"], ["git", "ls-files"], ["ls", "/tmp"]):
        assert mod._allowlisted(probe)[0], probe


def test_T_pr_queue_refuses_every_unrecognised_shape_not_just_one(tmp_path, monkeypatch):
    """[P2, review cycle 2] The shape refusal covered only `dict WITHOUT rows/prs`.

    Every other unreadable shape still fell into the loop and answered `row_count: 0, isError: false`
    — the confident empty queue invariant 1 forbids. An EMPTY LIST stays a real answer (an empty board
    is a measurement); anything unrecognised is an abstention.
    """
    mod = _saved_mod()
    monkeypatch = pytest.MonkeyPatch()
    try:
        for payload in ('{"foo": 1}', '{"rows": "nope"}', '{"rows": {}}', '42', '"a string"', '[1,2,3]'):
            ran = mod.Ran(["pr_state.py", "--json"], rc=0, stdout=payload)
            monkeypatch.setattr(mod, "run_module", lambda *a, **k: ran)
            is_err, out = mod._pr_queue(None, {"repo": "o/r"})
            assert "unmeasured" in out, (payload, out)
            assert out.get("row_count", 0) == 0 and "rows" not in out, (payload, out)
        # and an EMPTY LIST is still a legitimate measurement, not an abstention
        ran = mod.Ran(["pr_state.py", "--json"], rc=0, stdout="[]")
        monkeypatch.setattr(mod, "run_module", lambda *a, **k: ran)
        is_err, out = mod._pr_queue(None, {"repo": "o/r"})
        assert out["rows"] == [] and out["row_count"] == 0 and "unmeasured" not in out, out
    finally:
        monkeypatch.undo()


def test_T_lane_dispatch_fresh_branch_proceeds_and_remote_only_refuses(tmp_path, monkeypatch):
    """[P1, review cycle 2] `measured` is not `rc == 0`, and the two cases the guard exists for.

    `git rev-parse --verify --quiet refs/heads/<absent>` answers **rc=1 for a MEASURED ABSENCE** — that
    is how it says "no such branch". Treating `not exists.ok()` as unreadable inverted the guard: it
    refused every brand-new branch (the normal dispatch) and reported a branch the remote probe could
    SEE (`remote: true` in the same payload) as "unmeasured". These two arms are the ones missing.
    """
    import subprocess
    mod = _saved_mod()
    monkeypatch = pytest.MonkeyPatch()
    try:
        origin = tmp_path / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
        wt = tmp_path / "wt"
        subprocess.run(["git", "clone", "-q", str(origin), str(wt)], check=True)
        subprocess.run(["git", "-C", str(wt), "-c", "user.email=t@t", "-c", "user.name=t",
                        "commit", "-q", "--allow-empty", "-m", "x"], check=True)
        subprocess.run(["git", "-C", str(wt), "push", "-q", "origin", "HEAD:refs/heads/main"], check=True)
        brief = tmp_path / "b.md"
        brief.write_text("x")
        monkeypatch.setenv("O", str(tmp_path / "o"))
        (tmp_path / "o" / "bg").mkdir(parents=True)

        # (a) a FRESH branch, both probes readable → the dispatch must PROCEED (pid from the launcher)
        (tmp_path / "o" / "bg" / "F1.pid").write_text("999\n")
        monkeypatch.setenv("ORCH_MCP_DISPATCH", stub(tmp_path, "d-ok.sh", "print('launched')"))
        is_err, payload = one(mod, "lane.dispatch", {"name": "F1", "worktree": str(wt),
                                                    "brief": str(brief), "branch": "brand-new"})
        assert is_err is False and payload.get("pid") == 999, payload

        # (b) a branch that exists ONLY on the remote → a MEASURED collision, not an abstention
        subprocess.run(["git", "-C", str(wt), "push", "-q", "origin",
                        "HEAD:refs/heads/remote-only"], check=True)
        (tmp_path / "o" / "bg" / "F2.pid").write_text("998\n")
        is_err, payload = one(mod, "lane.dispatch", {"name": "F2", "worktree": str(wt),
                                                    "brief": str(brief), "branch": "remote-only"})
        assert is_err and payload["refused"] == "branch-exists", payload
    finally:
        monkeypatch.undo()


def test_T_lane_dispatch_local_field_and_unreadable_local_probe(tmp_path, monkeypatch):
    """[P2 x2, review cycle 3] Two halves of the same guard that nothing pinned.

    (a) A MEASURED absence (rc=1 from `rev-parse --verify --quiet`) must not be labelled UNMEASURED. The
        decision was right and the field lied about why, sending the reader to debug a local probe that
        had answered correctly while the remote was the thing that needed fixing.
    (b) `exists.rc in (0, 1)` is load-bearing: without it, a probe that could not RUN (rc=128 — a
        non-repo worktree) reads as a measured absence and the dispatch proceeds. That mutation left the
        whole selection green, so this arm constructs the case.
    """
    import subprocess
    mod = _saved_mod()
    monkeypatch = pytest.MonkeyPatch()
    try:
        brief = tmp_path / "b.md"
        brief.write_text("x")
        monkeypatch.setenv("O", str(tmp_path / "o"))
        (tmp_path / "o" / "bg").mkdir(parents=True)

        # (a) repo WITH a worktree but NO origin → local probe ANSWERS (rc=1, measured absent),
        #     remote probe fails → refusal, and `local` must be False, not UNMEASURED.
        wt = tmp_path / "wt"
        wt.mkdir()
        subprocess.run(["git", "init", "-q", str(wt)], check=True)
        subprocess.run(["git", "-C", str(wt), "-c", "user.email=t@t", "-c", "user.name=t",
                        "commit", "-q", "--allow-empty", "-m", "x"], check=True)
        is_err, payload = one(mod, "lane.dispatch", {"name": "P1", "worktree": str(wt),
                                                    "brief": str(brief), "branch": "nope-1"})
        assert is_err and payload["refused"] == "branch-existence-unmeasured", payload
        assert payload["local"] is False, payload          # MEASURED, not UNMEASURED
        assert "UNMEASURED(" in str(payload["remote"]), payload

        # (b) worktree is NOT a repo (the local probe cannot RUN, rc=128) WITH A READABLE ORIGIN whose
        #     branch list is empty. Both probes are stubbed because that is the only way to build this
        #     state portably — without the stub, `origin` is simply unreadable and the refusal fires on
        #     the REMOTE axis, so the arm would pass with the `rc in (0, 1)` guard removed (review
        #     cycle 4, P2: the guard's label was pinned, its decision was not).
        notrepo = tmp_path / "notrepo"
        notrepo.mkdir()
        def _stubbed_run(argv, *a, **k):
            if "rev-parse" in argv:          # local probe: COULD NOT RUN
                return mod.Ran(list(argv), rc=128, stderr="fatal: not a git repository")
            return mod.Ran(list(argv), rc=0, stdout="")   # remote probe: READ, and empty
        monkeypatch.setattr(mod, "run", _stubbed_run)
        (tmp_path / "o" / "bg" / "P2.pid").write_text("777\n")
        monkeypatch.setenv("ORCH_MCP_DISPATCH", stub(tmp_path, "d-ok2.sh", "print('launched')"))
        is_err, payload = one(mod, "lane.dispatch", {"name": "P2", "worktree": str(notrepo),
                                                    "brief": str(brief), "branch": "nope-2"})
        assert is_err and payload["refused"] == "branch-existence-unmeasured", payload
        assert "UNMEASURED(" in str(payload["local"]), payload
        # and the remote axis is genuinely MEASURED here — this is what makes the assertion above
        # discriminate on `rc in (0, 1)` rather than on an unreadable remote
        assert payload["remote"] is False, payload
    finally:
        monkeypatch.undo()


def test_T_box_exec_refuses_the_git_help_execution_channel():
    """[P1, review cycle 5] `git <admitted-verb> --help` executes a CONFIG-NAMED program.

    Measured on three verbs, from cwd `/` as well as inside a repo: `--help` does not print text, it
    renders the manual through `man.<tool>.cmd` / `man.viewer`, both of which name a program and both of
    which come from the repo's (or the box's global) config. It cannot be pinned — every `-c man.*` value
    tried still ran the repo's driver — and `_repo_config_fault` reads such a repo as CLEAN, so this
    refusal is the only closure. `-h` stays allowed: rc=129, usage text, no execution.
    """
    mod = _saved_mod()
    for argv in (["git", "status", "--help"], ["git", "rev-parse", "--help"],
                 ["git", "ls-files", "--help"], ["git", "status", "--help=web"]):
        ok, why = mod._allowlisted(argv)
        assert not ok, argv
        assert "--help" in why, (argv, why)
    # the short form is not an execution channel and stays admitted
    assert mod._allowlisted(["git", "status", "-h"])[0]
    assert mod._allowlisted(["git", "status"])[0]


def test_T_pin_the_help_boundary_shapes():
    """[P3, review cycle 5] The refusal must be 'THESE SHAPES', not 'anything containing help'.

    An over-broad rule (`if "help" in low:`) would false-block `-help`, which git treats as an unknown
    option (measured: rc=129, usage text, no execution). This arm pins both directions so the widening is
    a red, not a silent regression: refused forms stay refused, and the harmless spellings stay admitted.
    """
    mod = _saved_mod()
    for argv in (["git", "status", "--help"], ["git", "status", "--HELP"],
                 ["git", "status", "--Help=web"], ["git", "status", "--help="],
                 ["git", "rev-parse", "--help"], ["git", "ls-files", "--help"]):
        ok, why = mod._allowlisted(argv)
        assert not ok and "--help" in why, (argv, ok, why)
    # these are NOT execution channels (measured: usage text / unknown option / literal echo)
    for argv in (["git", "status", "-h"], ["git", "status", "-help"],
                 ["git", "status", "--hel"], ["git", "status", "--help-all"]):
        assert mod._allowlisted(argv)[0], argv
