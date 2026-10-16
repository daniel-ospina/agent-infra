#!/usr/bin/env python3
"""Proof that pr-doctor's dispatch path is the BACKGROUND one, and that the cap is the MACHINE's.

WHY THIS FILE EXISTS. Two properties were false for a day and no test noticed:

  * `scripts/pr-doctor.py` hardcoded `MAX_INFLIGHT = 4` "fleet-wide" while the box that runs it
    is configured for `MAX_FIX=16` / `MAX_REVIEW=12`, so the PR chain -- the path that drains the
    backlog -- was throttled to 4 with no way to override it from config.
  * the dispatch itself was a LANE-TABLE dispatcher: `idle_lanes()` + a cmux send to a workspace
    that already existed. When every lane was busy it logged `no idle lanes -- nothing dispatched`
    and gave up, so classified work sat unfixed while there was budget. The replacement --
    `nonblocking-dispatch.sh`, which spawns a fresh load-gated worker in the background -- was
    installed and called by nothing.

The rule these tests pin:
  * a threshold configured on the machine reaches the dispatch cap (per class);
  * the dispatch path is `nonblocking-dispatch.sh` (background), never a cmux lane send;
  * that background path is load-gated by `spawn-gate.sh`'s `run_agent()`; and
  * the retired lane-table feeding is GONE, not merely unused.

Run:  <venv>/bin/python -m pytest test_pr_doctor.py -q
"""
from __future__ import annotations

import importlib.util
import os
import pathlib
import re
import subprocess
import sys
import time

import pytest

_REPO = pathlib.Path(__file__).resolve().parent.parent
_SPEC = importlib.util.spec_from_file_location(
    "pr_doctor_under_test", pathlib.Path(__file__).with_name("pr-doctor.py"))
pr = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(pr)

_HARNESS = _REPO / "scripts" / "orchestrator-harness"


def _pr(number: int, head: str = "a" * 40) -> dict:
    return {"number": number, "title": "t%d" % number, "isDraft": False, "headRefOid": head,
            "headRefName": "fix/branch-%d" % number, "mergeStateStatus": "CLEAN", "files": []}


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    """A test must never inherit the developer's or the CI runner's capacity env."""
    for k in ("MAX_FIX", "MAX_REVIEW"):
        monkeypatch.delenv(k, raising=False)
    # Point the plist at a path that cannot exist, so a sandbox that happens to have the
    # orchestrator installed does not leak its values into a unit test.
    monkeypatch.setattr(pr, "ORCH_PLIST", "/nonexistent/pr-doctor-test/loop.plist", raising=False)


# ── 1. the machine's config reaches capacity() ────────────────────────────────────────────

def test_capacity_reads_environment_first(monkeypatch):
    monkeypatch.setenv("MAX_FIX", "16")
    monkeypatch.setenv("MAX_REVIEW", "12")
    cap = pr.capacity()
    assert cap == {"max_fix": 16, "max_review": 12}


def test_capacity_reads_the_orchestrator_plist(monkeypatch, tmp_path):
    """The SAME EnvironmentVariables block launchd feeds orch-loop.sh is what pr-doctor reads."""
    import plistlib
    plist = tmp_path / "com.eldato.orchestrator-loop.plist"
    with open(plist, "wb") as f:
        plistlib.dump({"Label": "com.eldato.orchestrator-loop",
                       "EnvironmentVariables": {"MAX_FIX": "16", "MAX_REVIEW": "12",
                                                "PATH": "/usr/bin"}}, f)
    monkeypatch.setattr(pr, "ORCH_PLIST", str(plist))
    assert pr.capacity() == {"max_fix": 16, "max_review": 12}


def test_environment_wins_over_the_plist(monkeypatch, tmp_path):
    import plistlib
    plist = tmp_path / "loop.plist"
    with open(plist, "wb") as f:
        plistlib.dump({"EnvironmentVariables": {"MAX_FIX": "16", "MAX_REVIEW": "12"}}, f)
    monkeypatch.setattr(pr, "ORCH_PLIST", str(plist))
    monkeypatch.setenv("MAX_FIX", "5")
    assert pr.capacity() == {"max_fix": 5, "max_review": 12}


def test_capacity_falls_back_to_the_loop_defaults(monkeypatch):
    """No env and no plist -> the shipped defaults, which MUST equal orch-loop.sh's.

    This is the anti-divergence half: pr-doctor may not invent a second capacity model. The
    values are extracted from the loop itself, not repeated here, so a change to one file that
    is not mirrored in the other goes RED.
    """
    loop = (_HARNESS / "orch-loop.sh").read_text()
    def _default(var):
        m = re.search(r'^%s="\$\{%s:-(\d+)\}"' % (var, var), loop, re.M)
        assert m, "orch-loop.sh no longer assigns %s with a :- default" % var
        return int(m.group(1))
    assert pr.capacity() == {"max_fix": _default("MAX_FIX"), "max_review": _default("MAX_REVIEW")}


@pytest.mark.parametrize("bad", ["nope", "", "-1", "9999999999",
                                      "010", "08", "1_000", "+12", " 12"])
def test_capacity_rejects_a_bad_value_and_uses_the_default(monkeypatch, bad):
    monkeypatch.setenv("MAX_FIX", bad)
    monkeypatch.setenv("MAX_REVIEW", "4")
    assert pr.capacity()["max_fix"] == pr.DEFAULT_MAX_FIX


def test_capacity_tolerates_a_plist_whose_root_is_not_a_dict(monkeypatch, tmp_path):
    """A well-formed plist whose root is not a mapping must fall back, never raise.

    `plistlib.load` succeeds for a top-level array/string/int, so the shape guard has to cover
    the ROOT too -- otherwise a corrupted or hand-edited plist aborts the whole pass instead of
    using the env/defaults.
    """
    import plistlib
    plist = tmp_path / "loop.plist"
    with open(plist, "wb") as f:
        plistlib.dump([{"Label": "com.eldato.orchestrator-loop"}], f)
    monkeypatch.setattr(pr, "ORCH_PLIST", str(plist))
    monkeypatch.setenv("MAX_FIX", "16")
    assert pr.capacity() == {"max_fix": 16, "max_review": pr.DEFAULT_MAX_REVIEW}


def test_orch_plist_path_is_pinned_to_install_sh_label():
    """The ONE home must not silently evaporate if the launchd label is renamed."""
    src = (_REPO / "scripts" / "pr-doctor.py").read_text()
    lm = re.search(r'ORCH_PLIST = os\.path\.join\(HOME, "Library", "LaunchAgents", "([^"]+)"\)', src)
    assert lm, "pr-doctor.py no longer builds ORCH_PLIST from a literal plist name"
    inst = (_HARNESS / "install.sh").read_text()
    im = re.search(r'^LABEL="([^"]+)"', inst, re.M)
    assert im, "install.sh no longer assigns LABEL with a quoted value"
    assert lm.group(1) == im.group(1) + ".plist"


# ── 2. the cap is consumed per class, and a stale row does not consume it ─────────────────

def test_inflight_consumes_its_own_class_budget():
    now = 1_000_000.0
    st = {"1": {"action": "failing", "at_epoch": now},
          "2": {"action": "unreviewed", "at_epoch": now},
          "_meta": {}}
    b = pr.pass_budgets(st, {"max_fix": 16, "max_review": 12}, now_epoch=now)
    assert (b["fix"], b["review"], b["total"]) == (15, 11, 26)


def test_a_stale_dispatch_stops_consuming_budget():
    now = 1_000_000.0
    st = {"1": {"action": "failing", "at_epoch": now - pr.STALE_DISPATCH_S - 1}}
    b = pr.pass_budgets(st, {"max_fix": 16, "max_review": 12}, now_epoch=now)
    assert b["total"] == 28


def test_max_override_is_a_hard_ceiling():
    b = pr.pass_budgets({}, {"max_fix": 16, "max_review": 12}, total_override=8)
    assert b["total"] == 8


# ── 3. the dispatch path is the BACKGROUND one, and it is LOAD-GATED ──────────────────────

def test_spawn_argv_is_the_background_dispatcher_not_cmux(monkeypatch):
    """The dispatch command must be `nonblocking-dispatch.sh`, never a cmux lane send.

    This is the assertion that was missing while the lane-table path ran: it would have been RED
    for the entire day the replacement was installed but called by nothing.
    """
    monkeypatch.setattr(pr, "NONBLOCKING_DISPATCH", "/opt/orch/nonblocking-dispatch.sh")
    argv = pr.spawn_argv("prd-7", "/repo/.worktrees/prd-7", "/state/brief.txt")
    assert argv[0] == "bash"
    assert argv[1] == "/opt/orch/nonblocking-dispatch.sh"
    assert argv[2] == "prd-7"
    assert argv[3] == "/repo/.worktrees/prd-7"
    assert argv[4] == "/state/brief.txt"
    assert "cmux" not in " ".join(argv)
    assert "cmux_dispatch" not in " ".join(argv)


def test_dispatch_invokes_the_background_spawn_argv(monkeypatch, tmp_path):
    calls = []
    monkeypatch.setattr(pr, "STATE_DIR", str(tmp_path))
    monkeypatch.setattr(pr, "log", lambda m: None)
    monkeypatch.setattr(pr, "materialise_worktree", lambda p: ("/wt/prd-9", ""))
    monkeypatch.setattr(pr, "NONBLOCKING_DISPATCH", "/opt/orch/nonblocking-dispatch.sh")

    def fake_sh_err(argv, timeout=180, cwd=None):
        calls.append(argv)
        return "launched prd-9 pid=1", "", 0

    monkeypatch.setattr(pr, "sh_err", fake_sh_err)
    ok, _ = pr.dispatch(_pr(9), "failing", "brief text", dry=False)
    assert ok is True
    assert calls, "dispatch did not invoke the spawn command"
    assert calls[0][1] == "/opt/orch/nonblocking-dispatch.sh"
    assert "cmux" not in " ".join(calls[0])


def test_dispatch_reports_a_failed_worktree_instead_of_spawning(monkeypatch, tmp_path):
    monkeypatch.setattr(pr, "STATE_DIR", str(tmp_path))
    monkeypatch.setattr(pr, "log", lambda m: None)
    monkeypatch.setattr(pr, "materialise_worktree",
                        lambda p: ("", "worktree add failed rc=1: boom"))
    called = []
    monkeypatch.setattr(pr, "sh_err", lambda *a, **k: called.append(a) or ("", "", 0))
    ok, detail = pr.dispatch(_pr(3), "failing", "x", dry=False)
    assert ok is False
    assert "worktree add failed" in detail
    assert not called, "nothing must be spawned when the worktree could not be materialised"


def test_nonblocking_dispatch_routes_through_run_agent(tmp_path):
    """Drive the REAL `nonblocking-dispatch.sh` against a stub `spawn-gate.sh`.

    A background dispatcher that carried its own spawn would never reach `run_agent()`. This
    asserts the call ARRIVES at the gate -- which is where the load gate lives -- by recording it.
    If the routing is ever "simplified" back to a direct `pi` spawn, this goes RED.
    """
    d = tmp_path / "orch"
    d.mkdir()
    marker = tmp_path / "marker.txt"
    (d / "spawn-gate.sh").write_text(
        'run_agent() { echo "GATED $*" > "$MARK"; echo ran; return 0; }\n')
    wt = tmp_path / "wt"
    wt.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=str(wt), check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    prompt = tmp_path / "brief.txt"
    prompt.write_text("do the thing\n")
    env = dict(os.environ, O=str(d), MARK=str(marker))
    nb = _HARNESS / "nonblocking-dispatch.sh"
    r = subprocess.run(["bash", str(nb), "prd-1", str(wt), str(prompt), "5"],
                       capture_output=True, text=True, env=env, timeout=60)
    assert r.returncode == 0, r.stderr
    for _ in range(100):
        if marker.exists():
            break
        time.sleep(0.05)
    assert marker.exists(), "nonblocking-dispatch.sh did not route through run_agent()"
    assert "GATED" in marker.read_text()


def test_load_gate_refuses_when_the_ceiling_is_reached():
    """`run_agent()` is the load gate, and it refuses with a NAMED code rather than spawning.

    Source-level, but on the actual gate: this is the property the background worker inherits.
    """
    gate = (_HARNESS / "spawn-gate.sh").read_text()
    assert "can_spawn()" in gate
    assert "AGENT_LOAD_REFUSED" in gate
    assert re.search(r'if ! can_spawn "\$l"; then', gate), \
        "run_agent no longer consults can_spawn() before the spawn"


def test_pr_doctor_never_spawns_pi_itself():
    """A private spawn path would bypass the gate -- the census in spawn-gate.test.sh refuses it."""
    src = (_REPO / "scripts" / "pr-doctor.py").read_text()
    # Split so this SUITE is not itself read as a pi-invoker by spawn-gate.test.sh's census (which
    # keys on the flag pair appearing as literals in a scripts/ file).
    no_session = "--no" + "-session"
    assert no_session not in src
    assert "pi -p" not in src
    assert not re.search(r'(^|[^[:alnum:]_-])(-p|--print)([^[:alnum:]_-]|$)', src)


# ── 4. the lane-table feeding is RETIRED, not merely unused ───────────────────────────────

def test_lane_table_feeding_is_gone_from_the_source():
    """`idle_lanes()` + a cmux send must not survive as a second, live path.

    ⛔ This is the step the previous dedup skipped, and skipping it is what inverted the change:
    a replacement that is added but not switched on is indistinguishable from no replacement,
    except that it hides the old one's flaws. The check is on the CODE (AST + string literals),
    not on comments, so naming the retired path in a comment is not itself a failure.
    """
    import ast
    src = (_REPO / "scripts" / "pr-doctor.py").read_text()
    tree = ast.parse(src)
    funcs = {n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
    literals = [n.value for n in ast.walk(tree)
                if isinstance(n, ast.Constant) and isinstance(n.value, str)]
    assert "idle_lanes" not in funcs
    assert not any("lane-actions" in s for s in literals)
    assert not any("cmux_dispatch" in s for s in literals)


# ── 5. the end-to-end dispatch cap is the configured one, not 4 ───────────────────────────

def _drive(monkeypatch, *, prs, action, cap_env, dispatch=None):
    """Run one dry pass with a stubbed world and return the dispatch labels it emitted."""
    sent = []
    monkeypatch.setattr(pr, "load_state", lambda: {})
    monkeypatch.setattr(pr, "open_prs", lambda: list(prs))
    monkeypatch.setattr(pr, "classify", lambda p: action(p) if callable(action) else action)
    monkeypatch.setattr(pr, "brief", lambda p, a: "brief-%s" % p["number"])
    monkeypatch.setattr(pr, "log", lambda msg: None)
    if dispatch is None:
        def dispatch(p, a, text, dry):
            sent.append("prd-%s" % p["number"])
            return True, ""
    monkeypatch.setattr(pr, "dispatch", dispatch)
    monkeypatch.setattr(sys, "argv", ["pr-doctor.py", "--dry-run"])
    monkeypatch.setenv("MAX_FIX", str(cap_env[0]))
    monkeypatch.setenv("MAX_REVIEW", str(cap_env[1]))
    assert pr.main() == 0
    return sent


def test_configured_capacity_reaches_the_dispatch_cap(monkeypatch):
    """The box is configured for 16/12, so 10 fix orders must all dispatch.

    On the old hardcoded `MAX_INFLIGHT = 4` this returns 4 labels; it fails before that fix and
    passes after.
    """
    sent = _drive(monkeypatch, prs=[_pr(n) for n in range(1, 11)],
                  action="failing", cap_env=(16, 12))
    assert len(sent) == 10


def test_work_is_dispatched_with_no_lane_table_at_all(monkeypatch):
    """A dispatch decision must not require a pre-existing idle lane with an assignment.

    There is no `idle_lanes` stub here -- and none exists in the module -- so the work is
    dispatched purely because it is classified and there is budget.
    """
    sent = _drive(monkeypatch, prs=[_pr(n) for n in range(1, 4)],
                  action="failing", cap_env=(16, 12))
    assert sent == ["prd-1", "prd-2", "prd-3"]


def test_fix_and_review_budgets_are_separate(monkeypatch):
    """The box distinguishes fix from review; pr-doctor must not collapse them into one cap."""
    prs = [_pr(n) for n in range(1, 11)]
    # 1..5 failing (fix), 6..10 unreviewed (review); ranked order puts unreviewed before failing.
    def classify(p):
        return "failing" if p["number"] <= 5 else "unreviewed"
    sent = _drive(monkeypatch, prs=prs, action=classify, cap_env=(2, 3))
    # 2 fix + 3 review = 5, even though 10 PRs are ready for work.
    assert len(sent) == 5
    fix = [s for s in sent if s in ("prd-1", "prd-2", "prd-3", "prd-4", "prd-5")]
    review = [s for s in sent if s in ("prd-6", "prd-7", "prd-8", "prd-9", "prd-10")]
    assert len(fix) == 2 and len(review) == 3
