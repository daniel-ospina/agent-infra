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
    monkeypatch.setattr(pr, "REFUSAL_WINDOW_S", 0.0)   # no .rc will appear; do not wait

    def fake_sh_err(argv, timeout=180, cwd=None):
        calls.append(argv)
        return "launched prd-9 pid=1", "", 0

    monkeypatch.setattr(pr, "sh_err", fake_sh_err)
    ok, _ = pr.dispatch(_pr(9), "failing", "brief text", dry=False)
    assert ok is True
    assert calls, "dispatch did not invoke the spawn command"
    assert calls[0][1] == "/opt/orch/nonblocking-dispatch.sh"
    assert "cmux" not in " ".join(calls[0])


def test_dispatch_does_not_record_a_gate_refusal(tmp_path, monkeypatch):
    """A load/disk refusal consumed NOTHING, so it must not be recorded as a dispatch.

    `nonblocking-dispatch.sh` backgrounds `run_agent()` and returns 0 immediately; the refusal
    code lands only in `$O/bg/<name>.rc`. Recording it would burn a 45-min cooldown and a 90-min
    budget slot for work that never ran -- a false PASS on the pass log.
    """
    d = tmp_path / "orch"
    d.mkdir()
    (d / "spawn-gate.sh").write_text("run_agent() { return 75; }\n")
    wt = tmp_path / "wt"
    wt.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=str(wt), check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    monkeypatch.setattr(pr, "STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(pr, "ORCH_DIR", str(d))
    monkeypatch.setattr(pr, "NONBLOCKING_DISPATCH", str(_HARNESS / "nonblocking-dispatch.sh"))
    monkeypatch.setattr(pr, "materialise_worktree", lambda p: (str(wt), ""))
    monkeypatch.setattr(pr, "log", lambda m: None)
    monkeypatch.setenv("O", str(d))
    ok, detail = pr.dispatch(_pr(11), "failing", "brief", dry=False)
    assert ok is False
    assert "refused" in detail and "75" in detail


def test_main_writes_no_state_row_for_a_refused_spawn(monkeypatch):
    saved = {}
    monkeypatch.setattr(pr, "load_state", lambda: {})
    monkeypatch.setattr(pr, "open_prs", lambda: [_pr(1)])
    monkeypatch.setattr(pr, "classify", lambda p: "failing")
    monkeypatch.setattr(pr, "brief", lambda p, a: "b")
    monkeypatch.setattr(pr, "log", lambda m: None)
    monkeypatch.setattr(pr, "dispatch", lambda p, a, t, d: (False, "gate refused rc=75"))
    monkeypatch.setattr(pr, "save_state", lambda st: saved.update(st))
    monkeypatch.setattr(sys, "argv", ["pr-doctor.py"])
    monkeypatch.setenv("MAX_FIX", "16")
    monkeypatch.setenv("MAX_REVIEW", "12")
    assert pr.main() == 0
    assert not [k for k in saved if not k.startswith("_")], \
        "a refused spawn must not consume a state row / budget slot"


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
    pat = r'(?:^|[^A-Za-z0-9_-])(?:-p|--print)(?:[^A-Za-z0-9_-]|$)'
    assert not re.search(pat, src)
    # non-vacuity: the same pattern FIRES on a real headless-spawn spelling (the Python `re`
    # module has no POSIX character classes, so `[^[:alnum:]_-]` matched nothing and this
    # assertion could never fail -- proven by driving it).
    assert re.search(pat, 'argv = ["pi", "-p", "x"]')


# ── 3b. the worktree recipe is liveness-checked and never destroys work ────────────────

def _git_repo(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()

    def g(*args, **kw):
        return subprocess.run(["git", "-C", str(repo)] + list(args), check=kw.pop("check", True),
                              capture_output=True, text=True)

    g("init", "-q")
    g("config", "user.email", "t@t")
    g("config", "user.name", "t")
    g("config", "commit.gpgsign", "false")
    (repo / "f.txt").write_text("base\n")
    g("add", "f.txt")
    g("commit", "-qm", "base")
    g("branch", "-M", "main")
    return repo, g


def _prb(number, head, branch):
    p = _pr(number, head)
    p["headRefName"] = branch
    return p


def _wire_repo(monkeypatch, repo):
    monkeypatch.setattr(pr, "REPO_DIR", str(repo))
    monkeypatch.setattr(pr, "WORKTREE_ROOT", str(repo / ".worktrees"))
    monkeypatch.setattr(pr, "log", lambda m: None)


def test_materialise_worktree_creates_then_reuses_at_the_head(monkeypatch, tmp_path):
    repo, g = _git_repo(tmp_path)
    g("branch", "feat/x")
    head = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    wt, err = pr.materialise_worktree(_prb(1, head, "feat/x"))
    assert err == "" and wt.endswith("prd-1")
    # second call reuses it (same path) without re-adding
    wt2, err2 = pr.materialise_worktree(_prb(1, head, "feat/x"))
    assert (wt2, err2) == (wt, "")


def test_materialise_preserves_a_dangling_directory_and_uses_a_fresh_path(monkeypatch, tmp_path):
    """A directory whose record was removed may hold a previous worker's files. It is NOT deleted:
    the PR is materialised at a `-d` fallback path and the directory is left for inspection.
    """
    import shutil
    repo, g = _git_repo(tmp_path)
    g("branch", "feat/x")
    head = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    wt, _ = pr.materialise_worktree(_prb(1, head, "feat/x"))
    assert (repo / ".worktrees" / "prd-1" / ".git").exists()
    (pathlib.Path(wt) / "wip.txt").write_text("uncommitted work\n")
    shutil.rmtree(repo / ".git" / "worktrees" / "prd-1")   # record gone, directory stays
    assert pr._live_worktree(wt) is False               # the trap the old check fell into
    wt2, err = pr.materialise_worktree(_prb(1, head, "feat/x"))
    assert err == "" and wt2 != wt and wt2.endswith("prd-1-d")
    assert (pathlib.Path(wt) / "wip.txt").read_text() == "uncommitted work\n", \
        "a directory that may hold work must never be deleted"
    assert pr._live_worktree(wt2)
    # a second call reuses the fallback path rather than adding yet another
    assert pr.materialise_worktree(_prb(1, head, "feat/x")) == (wt2, "")


def test_an_empty_dir_inside_the_main_checkout_is_not_a_live_worktree(monkeypatch, tmp_path):
    """⛔ `git rev-parse --is-inside-work-tree` is true for ANY directory inside the repo, so an
    EMPTY `.worktrees/prd-<n>` used to be reported LIVE; `rev-parse HEAD` then read the MAIN
    checkout, and a stale-head branch moved the MAIN branch pointer with `reset --hard`.
    """
    repo, g = _git_repo(tmp_path)
    g("checkout", "-q", "-b", "feat/x")
    (repo / "x.txt").write_text("x\n")
    g("add", "x.txt")
    g("commit", "-qm", "x")
    head = g("rev-parse", "HEAD").stdout.strip()
    g("checkout", "-q", "main")
    main_before = g("rev-parse", "HEAD").stdout.strip()
    assert head != main_before
    _wire_repo(monkeypatch, repo)
    path = repo / ".worktrees" / "prd-1"
    path.mkdir(parents=True)                 # empty dir, no .git -- the false-live trap
    assert pr._live_worktree(str(path)) is False, \
        "an empty directory inside the main checkout is not a worktree ROOT"
    wt, err = pr.materialise_worktree(_prb(1, head, "feat/x"))
    assert err == "" and wt == str(path)
    assert g("rev-parse", "refs/heads/main").stdout.strip() == main_before, \
        "the main checkout's branch pointer must not move"
    assert subprocess.run(["git", "-C", wt, "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True).stdout.strip() == str(path)
    assert subprocess.run(["git", "-C", wt, "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip() == head


def test_materialise_moves_a_behind_local_branch_to_the_pr_head(monkeypatch, tmp_path):
    """A local `feat/x` that lags the PR head must not be trusted: the fresh worktree is verified
    and moved to the PR head, so a fixer pushes on top of the right commit."""
    repo, g = _git_repo(tmp_path)
    g("checkout", "-q", "-b", "feat/x")
    (repo / "x.txt").write_text("x\n")
    g("add", "x.txt")
    g("commit", "-qm", "x")
    head = g("rev-parse", "HEAD").stdout.strip()
    g("checkout", "-q", "main")
    g("branch", "-f", "feat/x", "main")          # local branch BEHIND the PR head
    _wire_repo(monkeypatch, repo)
    wt, err = pr.materialise_worktree(_prb(1, head, "feat/x"))
    assert err == "" and wt
    assert subprocess.run(["git", "-C", wt, "rev-parse", "HEAD"], capture_output=True,
                          text=True).stdout.strip() == head


def test_materialise_refuses_when_liveness_cannot_be_determined(monkeypatch, tmp_path):
    """An unanswerable liveness probe must NOT select reuse: `True` (the old "assume live" rule)
    would run `_ensure_head` -> `reset --hard` against whatever `git -C <path>` resolves to."""
    repo, g = _git_repo(tmp_path)
    g("checkout", "-q", "-b", "feat/x")
    (repo / "x.txt").write_text("x\n")
    g("add", "x.txt")
    g("commit", "-qm", "x")
    head = g("rev-parse", "HEAD").stdout.strip()
    g("checkout", "-q", "main")
    main_before = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    path = repo / ".worktrees" / "prd-1"
    path.mkdir(parents=True)
    real = pr.sh_err

    def fake(argv, timeout=180, cwd=None):
        if "--show-toplevel" in argv:
            return "", "timed out", -1                 # UNKNOWN, not "not a worktree"
        return real(argv, timeout=timeout, cwd=cwd)

    monkeypatch.setattr(pr, "sh_err", fake)
    wt, err = pr.materialise_worktree(_prb(1, head, "feat/x"))
    assert wt == "" and "cannot determine" in err
    assert g("rev-parse", "refs/heads/main").stdout.strip() == main_before, \
        "an unanswerable probe must not reset anything"


def test_ensure_head_refuses_to_reset_when_cleanliness_is_unknown(monkeypatch, tmp_path):
    """`status --porcelain` failing with empty stdout used to read as CLEAN and reset --hard."""
    repo, g = _git_repo(tmp_path)
    g("branch", "feat/x")
    head1 = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    wt, _ = pr.materialise_worktree(_prb(1, head1, "feat/x"))
    real = pr.sh_err

    def fake(argv, timeout=180, cwd=None):
        if "cat-file" in argv:
            return "", "", 0                          # the PR head object IS present
        if "status" in argv and "--porcelain" in argv:
            return "", "fatal: probe failed", 1       # cannot determine cleanliness
        return real(argv, timeout=timeout, cwd=cwd)

    monkeypatch.setattr(pr, "sh_err", fake)
    err = pr._ensure_head(wt, "feat/x", "0" * 40)
    assert "cannot determine" in err
    assert subprocess.run(["git", "-C", wt, "rev-parse", "HEAD"], capture_output=True,
                          text=True).stdout.strip() == head1, \
        "a worktree whose cleanliness is unknown must never be reset"


def test_materialise_clears_a_stranded_detached_record(monkeypatch, tmp_path):
    """A fork-PR worktree is DETACHED, so `worktree list --porcelain` has no `branch` line. Its
    stranded record must still be cleared, or `worktree add <prd-n>` fails for ever."""
    import shutil
    repo, g = _git_repo(tmp_path)
    head = g("rev-parse", "HEAD").stdout.strip()
    g("branch", "feat/x")
    _wire_repo(monkeypatch, repo)
    path = repo / ".worktrees" / "prd-1"
    g("worktree", "add", "--detach", str(path), head)
    shutil.rmtree(path)
    assert any(os.path.realpath(p) == os.path.realpath(str(path)) for p, _ in pr._worktrees()), \
        "a detached worktree must appear in _worktrees() with an empty ref"
    wt, err = pr.materialise_worktree(_prb(1, head, "feat/x"))
    assert err == "" and wt == str(path)


def test_materialise_reuses_only_a_worktree_on_the_pr_branch(monkeypatch, tmp_path):
    """A live worktree left on ANOTHER branch must not be silently reset: the worker's push would
    land on the wrong branch. It is switched back to the PR branch (or refused when dirty)."""
    repo, g = _git_repo(tmp_path)
    g("branch", "feat/x")
    head1 = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    wt, _ = pr.materialise_worktree(_prb(1, head1, "feat/x"))

    def gw(*a):
        return subprocess.run(["git", "-C", wt] + list(a), check=True,
                              capture_output=True, text=True)

    gw("checkout", "-q", "-b", "some-other-branch")
    wt2, err = pr.materialise_worktree(_prb(1, head1, "feat/x"))
    assert err == "" and wt2 == wt
    assert gw("symbolic-ref", "--short", "HEAD").stdout.strip() == "feat/x"


def test_materialise_refuses_to_switch_a_dirty_worktree_to_the_pr_branch(monkeypatch, tmp_path):
    repo, g = _git_repo(tmp_path)
    g("branch", "feat/x")
    head1 = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    wt, _ = pr.materialise_worktree(_prb(1, head1, "feat/x"))

    def gw(*a):
        return subprocess.run(["git", "-C", wt] + list(a), check=True,
                              capture_output=True, text=True)

    gw("checkout", "-q", "-b", "some-other-branch")
    (pathlib.Path(wt) / "f.txt").write_text("tracked change\n")
    wt2, err = pr.materialise_worktree(_prb(1, head1, "feat/x"))
    assert wt2 == "" and "uncommitted" in err
    assert (pathlib.Path(wt) / "f.txt").read_text() == "tracked change\n"


def test_materialise_clears_a_locked_stranded_record(monkeypatch, tmp_path):
    """A single `--force` does not remove a LOCKED record; without a double force the record
    survives and `worktree add` fails on every pass."""
    import shutil
    repo, g = _git_repo(tmp_path)
    head = g("rev-parse", "HEAD").stdout.strip()
    g("branch", "feat/x")
    _wire_repo(monkeypatch, repo)
    path = repo / ".worktrees" / "prd-1"
    g("worktree", "add", "--detach", str(path), head)
    g("worktree", "lock", str(path))
    shutil.rmtree(path)
    wt, err = pr.materialise_worktree(_prb(1, head, "feat/x"))
    assert err == "" and wt == str(path)


def test_materialise_never_deletes_a_dot_git_directory(monkeypatch, tmp_path):
    """A `.git` DIRECTORY is a repository's object store, not a dangling worktree pointer."""
    repo, g = _git_repo(tmp_path)
    head = g("rev-parse", "HEAD").stdout.strip()
    g("branch", "feat/x")
    _wire_repo(monkeypatch, repo)
    path = repo / ".worktrees" / "prd-1"
    (path / ".git" / "objects").mkdir(parents=True)
    (path / ".git" / "objects" / "someobj").write_text("precious\n")
    assert pr._disposable_dangling(str(path)) is False
    wt, err = pr.materialise_worktree(_prb(1, head, "feat/x"))
    assert err == "" and wt.endswith("prd-1-d"), "a `.git` directory must not be deleted"
    assert (path / ".git" / "objects" / "someobj").read_text() == "precious\n"


def test_a_symlink_alias_of_the_main_checkout_is_not_a_live_worktree(monkeypatch, tmp_path):
    """`--show-toplevel` resolves the symlink to the repo, so toplevel == realpath(path); only the
    git-dir/common-dir identity check rejects it -- without it, checkout/reset hits MAIN."""
    repo, g = _git_repo(tmp_path)
    g("checkout", "-q", "-b", "feat/x")
    (repo / "x.txt").write_text("x\n")
    g("add", "x.txt")
    g("commit", "-qm", "x")
    head = g("rev-parse", "HEAD").stdout.strip()
    g("checkout", "-q", "main")
    main_before = g("rev-parse", "refs/heads/main").stdout.strip()
    _wire_repo(monkeypatch, repo)
    (repo / ".worktrees").mkdir()
    link = repo / ".worktrees" / "prd-1"
    link.symlink_to(repo)
    assert pr._live_worktree(str(link)) is False, "a symlink alias of the main checkout is not a worktree"
    wt, err = pr.materialise_worktree(_prb(1, head, "feat/x"))
    assert g("rev-parse", "refs/heads/main").stdout.strip() == main_before, \
        "the main checkout must never be checked out or reset"
    assert err == "" and wt.endswith("prd-1-d")   # the symlink is preserved, `-d` is used


def test_a_gitdir_file_pointing_at_main_is_not_a_live_worktree(monkeypatch, tmp_path):
    """A `.git` FILE that points at the main git dir satisfies toplevel == path but is the MAIN
    repository; the git-dir/common-dir identity check must reject it."""
    repo, g = _git_repo(tmp_path)
    g("checkout", "-q", "-b", "feat/x")
    (repo / "x.txt").write_text("x\n")
    g("add", "x.txt")
    g("commit", "-qm", "x")
    head = g("rev-parse", "HEAD").stdout.strip()
    g("checkout", "-q", "main")
    main_before = g("rev-parse", "refs/heads/main").stdout.strip()
    _wire_repo(monkeypatch, repo)
    path = repo / ".worktrees" / "prd-1"
    path.mkdir(parents=True)
    (path / ".git").write_text("gitdir: %s\n" % (repo / ".git"))
    (path / "f.txt").write_text("ghost\n")
    assert pr._live_worktree(str(path)) is False
    wt, err = pr.materialise_worktree(_prb(1, head, "feat/x"))
    assert g("rev-parse", "refs/heads/main").stdout.strip() == main_before
    assert err == "" and wt.endswith("prd-1-d")


def test_materialise_detaches_a_fork_worktree_from_a_foreign_branch(monkeypatch, tmp_path):
    """A fork PR has no local branch, so a reused worktree must be DETACHED -- never left on a
    foreign local branch, whose pointer `_ensure_head` would otherwise move."""
    repo, g = _git_repo(tmp_path)
    head = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    path = repo / ".worktrees" / "prd-1"
    g("worktree", "add", "--detach", str(path), head)

    def gw(*a):
        return subprocess.run(["git", "-C", str(path)] + list(a), check=True,
                              capture_output=True, text=True)

    gw("checkout", "-q", "-b", "unrelated")
    gw("commit", "--allow-empty", "-qm", "c2")
    foreign_before = g("rev-parse", "refs/heads/unrelated").stdout.strip()
    p = _prb(1, head, "no-such-branch")
    p["isCrossRepository"] = True                    # a fork PR: no local branch to attach to
    wt, err = pr.materialise_worktree(p)
    assert err == "" and wt == str(path)
    assert g("rev-parse", "refs/heads/unrelated").stdout.strip() == foreign_before, \
        "a foreign branch must not be moved by the reset"
    assert gw("rev-parse", "HEAD").stdout.strip() == head


def test_materialise_resets_over_non_colliding_untracked_scratch(monkeypatch, tmp_path):
    """A leftover untracked scratch file must NOT block a reset the way `reset --hard` (which
    leaves non-colliding untracked files alone) would not be harmed by."""
    repo, g = _git_repo(tmp_path)
    g("branch", "feat/x")
    head1 = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    wt, _ = pr.materialise_worktree(_prb(1, head1, "feat/x"))

    def gw(*a):
        return subprocess.run(["git", "-C", wt] + list(a), check=True,
                              capture_output=True, text=True)

    gw("commit", "--allow-empty", "-qm", "second")
    head2 = gw("rev-parse", "HEAD").stdout.strip()
    gw("checkout", "-q", "--detach", head1)
    (pathlib.Path(wt) / "scratch.txt").write_text("scratch\n")
    wt2, err = pr.materialise_worktree(_prb(1, head2, "feat/x"))
    assert err == "" and wt2 == wt
    assert gw("rev-parse", "HEAD").stdout.strip() == head2
    assert (pathlib.Path(wt) / "scratch.txt").read_text() == "scratch\n"


def test_materialise_refuses_a_reset_that_would_overwrite_untracked_files(monkeypatch, tmp_path):
    """`reset --hard` DELETES an untracked file that collides with a path the PR head tracks."""
    repo, g = _git_repo(tmp_path)
    g("branch", "feat/x")
    head1 = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    wt, _ = pr.materialise_worktree(_prb(1, head1, "feat/x"))

    def gw(*a):
        return subprocess.run(["git", "-C", wt] + list(a), check=True,
                              capture_output=True, text=True)

    (pathlib.Path(wt) / "new.txt").write_text("committed at head2\n")
    gw("add", "new.txt")
    gw("commit", "-qm", "add new.txt")
    head2 = gw("rev-parse", "HEAD").stdout.strip()
    gw("reset", "--hard", head1)                    # new.txt removed (was tracked)
    (pathlib.Path(wt) / "new.txt").write_text("untracked precious\n")   # now untracked
    assert gw("symbolic-ref", "--short", "HEAD").stdout.strip() == "feat/x"
    wt2, err = pr.materialise_worktree(_prb(1, head2, "feat/x"))
    assert wt2 == "" and "untracked" in err
    assert (pathlib.Path(wt) / "new.txt").read_text() == "untracked precious\n"


def test_materialise_refuses_a_reset_when_a_tracked_file_shadows_an_untracked_dir(monkeypatch, tmp_path):
    """Conflict is by path COMPONENT: an untracked `dir/precious` collides with a tracked FILE
    `dir`, which string equality misses -- and `reset --hard` then deletes the untracked tree."""
    repo, g = _git_repo(tmp_path)
    g("branch", "feat/x")
    head1 = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    wt, _ = pr.materialise_worktree(_prb(1, head1, "feat/x"))

    def gw(*a):
        return subprocess.run(["git", "-C", wt] + list(a), check=True,
                              capture_output=True, text=True)

    (pathlib.Path(wt) / "dir").write_text("file at head2\n")
    gw("add", "dir")
    gw("commit", "-qm", "tracked file dir")
    head2 = gw("rev-parse", "HEAD").stdout.strip()
    gw("reset", "--hard", head1)                    # the tracked `dir` FILE is gone
    (pathlib.Path(wt) / "dir").mkdir()               # now an UNTRACKED DIRECTORY `dir/`
    (pathlib.Path(wt) / "dir" / "precious.txt").write_text("precious\n")
    wt2, err = pr.materialise_worktree(_prb(1, head2, "feat/x"))
    assert wt2 == "" and "untracked" in err
    assert (pathlib.Path(wt) / "dir" / "precious.txt").read_text() == "precious\n"


def test_untracked_clobber_catches_a_tracked_dir_shadowed_by_an_untracked_file(monkeypatch, tmp_path):
    """The reverse shape: head tracks `dir/file`, the worktree has an untracked FILE `dir`."""
    repo, g = _git_repo(tmp_path)
    head1 = g("rev-parse", "HEAD").stdout.strip()
    (repo / "dir").mkdir()
    (repo / "dir" / "file.txt").write_text("x\n")
    g("add", "-A")
    g("commit", "-qm", "track dir/file")
    head2 = g("rev-parse", "HEAD").stdout.strip()
    g("reset", "-q", "--hard", head1)
    (repo / "dir").write_text("untracked file\n")   # untracked FILE named `dir`
    assert os.path.isdir(repo / "dir") is False
    assert pr._untracked_clobber(str(repo), head2) == ["dir"]


def test_a_gitdir_file_pointing_at_another_worktree_is_not_live(monkeypatch, tmp_path):
    """A `.git` FILE pointing at ANOTHER worktree's git dir passes the git-dir checks but is a
    DIFFERENT worktree; accepting it would switch that worktree's branch out from under it."""
    repo, g = _git_repo(tmp_path)
    head = g("rev-parse", "HEAD").stdout.strip()
    g("branch", "b1")
    g("branch", "b2")
    wt2 = repo / ".worktrees" / "wt2"
    g("worktree", "add", str(wt2), "b2")
    _wire_repo(monkeypatch, repo)
    alias = repo / ".worktrees" / "prd-1"
    alias.mkdir(parents=True)
    (alias / ".git").write_text("gitdir: %s\n" % (repo / ".git" / "worktrees" / "wt2"))
    (alias / "f.txt").write_text("ghost\n")
    assert pr._live_worktree(str(alias)) is False
    b2_before = g("rev-parse", "refs/heads/b2").stdout.strip()
    wt, err = pr.materialise_worktree(_prb(1, head, "b1"))
    assert err == "" and wt.endswith("prd-1-d")
    assert g("rev-parse", "refs/heads/b2").stdout.strip() == b2_before
    assert subprocess.run(["git", "-C", str(wt2), "symbolic-ref", "--short", "HEAD"],
                          capture_output=True, text=True).stdout.strip() == "b2"


def test_materialise_refuses_a_reset_that_would_overwrite_an_ignored_file(monkeypatch, tmp_path):
    """`reset --hard` overwrites an IGNORED untracked file whose path the PR head tracks; git
    gives no warning for ignored files, so the guard must include them."""
    repo, g = _git_repo(tmp_path)
    (repo / ".gitignore").write_text("secret.txt\n")
    g("add", ".gitignore")
    g("commit", "-qm", "ignore secret")
    head1 = g("rev-parse", "HEAD").stdout.strip()
    g("branch", "feat/x")
    _wire_repo(monkeypatch, repo)
    wt, _ = pr.materialise_worktree(_prb(1, head1, "feat/x"))

    def gw(*a):
        return subprocess.run(["git", "-C", wt] + list(a), check=True,
                              capture_output=True, text=True)

    (pathlib.Path(wt) / "secret.txt").write_text("tracked at head2\n")
    gw("add", "-f", "secret.txt")
    gw("commit", "-qm", "track secret")
    head2 = gw("rev-parse", "HEAD").stdout.strip()
    gw("reset", "--hard", head1)                     # secret.txt gone; now ignored-untracked
    (pathlib.Path(wt) / "secret.txt").write_text("PRECIOUS IGNORED\n")
    wt2, err = pr.materialise_worktree(_prb(1, head2, "feat/x"))
    assert wt2 == "" and "untracked" in err
    assert (pathlib.Path(wt) / "secret.txt").read_text() == "PRECIOUS IGNORED\n"


def test_materialise_refuses_a_branch_switch_that_would_overwrite_an_ignored_file(monkeypatch, tmp_path):
    """`checkout <branch>` silently overwrites an ignored untracked file too; the switch must be
    refused before it runs."""
    repo, g = _git_repo(tmp_path)
    (repo / ".gitignore").write_text("secret.txt\n")
    g("add", ".gitignore")
    g("commit", "-qm", "ignore secret")
    base = g("rev-parse", "HEAD").stdout.strip()
    g("checkout", "-q", "-b", "feat/x")
    (repo / "secret.txt").write_text("tracked at head\n")
    g("add", "-f", "secret.txt")
    g("commit", "-qm", "track secret")
    head = g("rev-parse", "HEAD").stdout.strip()
    g("checkout", "-q", "main")
    _wire_repo(monkeypatch, repo)
    path = repo / ".worktrees" / "prd-1"
    g("worktree", "add", "--detach", str(path), base)
    (path / "secret.txt").write_text("PRECIOUS IGNORED\n")   # ignored, not tracked at base
    wt, err = pr.materialise_worktree(_prb(1, head, "feat/x"))
    assert wt == "" and "untracked" in err
    assert (path / "secret.txt").read_text() == "PRECIOUS IGNORED\n"


def test_materialise_refuses_to_rewind_a_worktree_ahead_of_the_pr_head(monkeypatch, tmp_path):
    """A CLEAN worktree can hold LOCAL COMMITS the PR head does not (unpushed worker work);
    `reset --hard` would rewind the branch and orphan them."""
    repo, g = _git_repo(tmp_path)
    g("branch", "feat/x")
    head1 = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    wt, _ = pr.materialise_worktree(_prb(1, head1, "feat/x"))

    def gw(*a):
        return subprocess.run(["git", "-C", wt] + list(a), check=True,
                              capture_output=True, text=True)

    (pathlib.Path(wt) / "worker.txt").write_text("worker work\n")
    gw("add", "worker.txt")
    gw("commit", "-qm", "local worker commit")
    head2 = gw("rev-parse", "HEAD").stdout.strip()
    assert head2 != head1
    wt2, err = pr.materialise_worktree(_prb(1, head1, "feat/x"))   # PR head is still the OLD one
    assert wt2 == "" and "commit" in err
    assert gw("rev-parse", "HEAD").stdout.strip() == head2, "the local commit must not be orphaned"
    assert (pathlib.Path(wt) / "worker.txt").exists()


def test_materialise_refuses_to_orphan_commits_on_a_detached_head(monkeypatch, tmp_path):
    """A detached HEAD whose commit no branch holds must not be switched away from -- the
    checkout in `_ensure_branch` would orphan it."""
    repo, g = _git_repo(tmp_path)
    g("branch", "feat/x")
    head1 = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    wt, _ = pr.materialise_worktree(_prb(1, head1, "feat/x"))

    def gw(*a):
        return subprocess.run(["git", "-C", wt] + list(a), check=True,
                              capture_output=True, text=True)

    gw("checkout", "-q", "--detach")
    (pathlib.Path(wt) / "only-here.txt").write_text("x\n")
    gw("add", "only-here.txt")
    gw("commit", "-qm", "detached only")
    head2 = gw("rev-parse", "HEAD").stdout.strip()
    wt2, err = pr.materialise_worktree(_prb(1, head1, "feat/x"))
    assert wt2 == "" and "orphan" in err
    assert gw("rev-parse", "HEAD").stdout.strip() == head2
    assert (pathlib.Path(wt) / "only-here.txt").exists()


def test_a_symlink_to_another_worktree_is_not_live(monkeypatch, tmp_path):
    """A symlink at a candidate path pointing at ANOTHER worktree resolves to a registered path,
    so only an explicit `islink` rejection stops the branch hijack."""
    repo, g = _git_repo(tmp_path)
    head = g("rev-parse", "HEAD").stdout.strip()
    g("branch", "b1")
    g("branch", "b2")
    wt2 = repo / ".worktrees" / "wt2"
    g("worktree", "add", str(wt2), "b2")
    _wire_repo(monkeypatch, repo)
    link = repo / ".worktrees" / "prd-1"
    link.symlink_to(wt2)
    assert pr._live_worktree(str(link)) is False
    b2_before = g("rev-parse", "refs/heads/b2").stdout.strip()
    wt, err = pr.materialise_worktree(_prb(1, head, "b1"))
    assert err == "" and wt.endswith("prd-1-d")
    assert g("rev-parse", "refs/heads/b2").stdout.strip() == b2_before
    assert subprocess.run(["git", "-C", str(wt2), "symbolic-ref", "--short", "HEAD"],
                          capture_output=True, text=True).stdout.strip() == "b2"


def test_materialise_does_not_materialise_through_a_symlink_to_an_empty_dir(monkeypatch, tmp_path):
    """A symlink to an EMPTY dir looks disposable (`listdir` follows it) but `rmtree` refuses it,
    and `worktree add` would then follow the symlink and create the worktree in the TARGET."""
    repo, g = _git_repo(tmp_path)
    head = g("rev-parse", "HEAD").stdout.strip()
    g("branch", "b1")
    _wire_repo(monkeypatch, repo)
    target = tmp_path / "emptydir"
    target.mkdir()
    (repo / ".worktrees").mkdir()
    link = repo / ".worktrees" / "prd-1"
    link.symlink_to(target)
    assert pr._disposable_dangling(str(link)) is False
    wt, err = pr.materialise_worktree(_prb(1, head, "b1"))
    assert err == "" and wt.endswith("prd-1-d")
    assert link.is_symlink(), "the symlink must be left alone"
    assert list(target.iterdir()) == [], "the symlink target must not receive a worktree"


def test_materialise_does_not_treat_a_dangling_symlink_as_a_free_path(monkeypatch, tmp_path):
    """A symlink to a NONEXISTENT path fails `os.path.exists`, so it looked free; `worktree add`
    then failed "already exists" on every pass and the `-d` candidate was never tried."""
    repo, g = _git_repo(tmp_path)
    head = g("rev-parse", "HEAD").stdout.strip()
    g("branch", "b1")
    _wire_repo(monkeypatch, repo)
    (repo / ".worktrees").mkdir()
    link = repo / ".worktrees" / "prd-1"
    link.symlink_to(tmp_path / "absent")
    assert os.path.islink(str(link)) and not os.path.exists(str(link))
    wt, err = pr.materialise_worktree(_prb(1, head, "b1"))
    assert err == "" and wt.endswith("prd-1-d")
    assert link.is_symlink()
    assert not (tmp_path / "absent").exists(), "nothing may be created through the symlink"


def test_materialise_fork_pr_ignores_a_colliding_local_branch(monkeypatch, tmp_path):
    """A fork PR's headRefName can equal a local branch (e.g. a fork of `main`); it must be
    materialised DETACHED at refs/pull/<n>/head and must not touch that local branch."""
    repo, g = _git_repo(tmp_path)
    g("branch", "develop")                           # a colliding local branch
    g("checkout", "-q", "-b", "fork-tmp")
    (repo / "fork.txt").write_text("fork\n")
    g("add", "fork.txt")
    g("commit", "-qm", "fork commit")
    forkhead = g("rev-parse", "HEAD").stdout.strip()
    g("checkout", "-q", "main")
    g("update-ref", "refs/pull/9/head", forkhead)
    g("remote", "add", "origin", str(repo))
    _wire_repo(monkeypatch, repo)
    develop_before = g("rev-parse", "refs/heads/develop").stdout.strip()
    p = _prb(9, forkhead, "develop")
    p["isCrossRepository"] = True
    wt, err = pr.materialise_worktree(p)
    assert err == "" and wt.endswith("prd-9")
    assert subprocess.run(["git", "-C", wt, "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip() == forkhead
    assert subprocess.run(["git", "-C", wt, "symbolic-ref", "-q", "--short", "HEAD"],
                          capture_output=True, text=True).returncode != 0, "a fork worktree is detached"
    assert g("rev-parse", "refs/heads/develop").stdout.strip() == develop_before


def test_materialise_reuse_of_a_fork_worktree_fetches_the_pr_ref(monkeypatch, tmp_path):
    """A fork's new head exists only at refs/pull/<n>/head; reuse must fetch THAT ref, not
    origin/<branch> (which does not exist for a fork)."""
    origin = tmp_path / "origin.git"
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True, capture_output=True)
    repo, g = _git_repo(tmp_path)
    g("remote", "add", "origin", str(origin))
    g("push", "-q", "origin", "main")
    fork = tmp_path / "fork"
    subprocess.run(["git", "clone", "-q", str(origin), str(fork)], check=True, capture_output=True)

    def fg(*a):
        return subprocess.run(["git", "-C", str(fork)] + list(a), check=True,
                              capture_output=True, text=True)

    fg("config", "user.email", "t@t")
    fg("config", "user.name", "t")
    (fork / "f1.txt").write_text("f1\n")
    fg("add", "f1.txt")
    fg("commit", "-qm", "f1")
    h1 = fg("rev-parse", "HEAD").stdout.strip()
    fg("push", "-q", "--force", "origin", "HEAD:refs/pull/7/head")
    _wire_repo(monkeypatch, repo)
    p1 = _prb(7, h1, "forkbranch")
    p1["isCrossRepository"] = True
    wt, err = pr.materialise_worktree(p1)          # h1 is absent locally -> must be fetched
    assert err == "" and wt.endswith("prd-7")

    (fork / "f2.txt").write_text("f2\n")
    fg("add", "f2.txt")
    fg("commit", "-qm", "f2")
    h2 = fg("rev-parse", "HEAD").stdout.strip()
    fg("push", "-q", "--force", "origin", "HEAD:refs/pull/7/head")
    p2 = _prb(7, h2, "forkbranch")
    p2["isCrossRepository"] = True
    wt2, err2 = pr.materialise_worktree(p2)        # h2 is absent locally -> reuse must fetch
    assert err2 == "" and wt2 == wt
    assert subprocess.run(["git", "-C", wt, "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip() == h2


def test_materialise_worktree_clears_a_stranded_record(monkeypatch, tmp_path):
    """Directory gone but the record remains: `worktree add` refuses until the record is cleared."""
    import shutil
    repo, g = _git_repo(tmp_path)
    g("branch", "feat/x")
    head = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    wt, _ = pr.materialise_worktree(_prb(1, head, "feat/x"))
    shutil.rmtree(wt)
    wt2, err = pr.materialise_worktree(_prb(1, head, "feat/x"))
    assert err == "" and wt2 == wt
    assert pr._live_worktree(wt2)


def test_materialise_worktree_resets_a_stale_clean_worktree(monkeypatch, tmp_path):
    repo, g = _git_repo(tmp_path)
    g("branch", "feat/x")
    head1 = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    wt, _ = pr.materialise_worktree(_prb(1, head1, "feat/x"))

    def gw(*a):
        return subprocess.run(["git", "-C", wt] + list(a), check=True,
                              capture_output=True, text=True)

    gw("commit", "--allow-empty", "-qm", "second")
    head2 = gw("rev-parse", "HEAD").stdout.strip()
    gw("checkout", "--detach", head1)                      # worktree back at the old head, clean
    wt2, err = pr.materialise_worktree(_prb(1, head2, "feat/x"))
    assert err == "" and wt2 == wt
    assert gw("rev-parse", "HEAD").stdout.strip() == head2


def test_materialise_worktree_refuses_to_reset_a_dirty_stale_worktree(monkeypatch, tmp_path):
    repo, g = _git_repo(tmp_path)
    g("branch", "feat/x")
    head1 = g("rev-parse", "HEAD").stdout.strip()
    _wire_repo(monkeypatch, repo)
    wt, _ = pr.materialise_worktree(_prb(1, head1, "feat/x"))

    def gw(*a):
        return subprocess.run(["git", "-C", wt] + list(a), check=True,
                              capture_output=True, text=True)

    gw("commit", "--allow-empty", "-qm", "second")
    head2 = gw("rev-parse", "HEAD").stdout.strip()
    gw("checkout", "--detach", head1)
    (pathlib.Path(wt) / "f.txt").write_text("uncommitted change\n")   # a TRACKED modification
    wt2, err = pr.materialise_worktree(_prb(1, head2, "feat/x"))
    assert wt2 == "" and "uncommitted" in err
    assert (pathlib.Path(wt) / "f.txt").read_text() == "uncommitted change\n", \
        "a dirty worktree must never be reset"


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
