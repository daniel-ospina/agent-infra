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
import threading
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
    monkeypatch.setattr(pr, "CONFIRM_WINDOW_S", 0.0)   # no .rc will appear; do not wait
    # two pre-spawn liveness probes (both "not live"), then the post-window confirmation
    statuses = iter(["lost", "lost", "running"])
    monkeypatch.setattr(pr, "worker_status", lambda name: next(statuses))

    def fake_sh_err(argv, timeout=180, cwd=None, env=None, capture=True):
        calls.append((argv, capture))
        return "", "", 0

    monkeypatch.setattr(pr, "sh_err", fake_sh_err)
    ok, _, record = pr.dispatch(_pr(9), "failing", "brief text", dry=False)
    assert ok is True and record is True
    assert calls, "dispatch did not invoke the spawn command"
    argv, capture = calls[-1]
    assert argv[1] == "/opt/orch/nonblocking-dispatch.sh"
    assert "cmux" not in " ".join(argv)
    # ⛔ NON-VACUITY for the P0: a CAPTURED spawn call blocks until the worker's stdout pipe
    # closes, i.e. for the worker's whole life. See
    # test_dispatch_returns_promptly_whatever_the_worker_does below (real harness, real worker).
    assert capture is False, "the spawn call must not capture the worker's inherited pipe"


def test_dispatch_does_not_record_a_gate_refusal(tmp_path, monkeypatch):
    """A load/disk refusal consumed NOTHING, so it must not be recorded as a dispatch.

    `nonblocking-dispatch.sh` backgrounds `run_agent()` and returns 0 immediately; the refusal
    code lands only in `$O/bg/<name>.rc`. Recording it would burn a 45-min cooldown and a 90-min
    budget slot for work that never ran -- a false PASS on the pass log.
    """
    d = tmp_path / "orch"
    d.mkdir()
    # ⛔ the marker is what distinguishes a GATE refusal from a `pi` that exited 75 itself; the
    # real spawn-gate.sh writes it to the worker log before returning, so a stub that only returns
    # 75 is not a gate refusal. (`test_the_refusal_markers_are_the_gates_own_lines` pins the text.)
    (d / "spawn-gate.sh").write_text(
        'run_agent() { echo "[load-gate] REFUSED bg: load=99 >= max_load=40" >> "$2"; return 75; }\n')
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
    ok, detail, record = pr.dispatch(_pr(11), "failing", "brief", dry=False)
    assert ok is False and record is False
    assert "refused" in detail.lower() and "75" in detail


def test_dispatch_records_an_unmaterialisable_worktree(tmp_path, monkeypatch):
    """A worktree refusal does NOT clear by waiting, so it must consume a cooldown.

    Without the row the pass logs the same line every cycle for ever and the PR never appears in
    `--status`. The gate-refusal case above is the OPPOSITE rule: nothing consumed, nothing burnt.
    """
    monkeypatch.setattr(pr, "STATE_DIR", str(tmp_path))
    monkeypatch.setattr(pr, "log", lambda m: None)
    monkeypatch.setattr(pr, "worker_status", lambda name: "lost")
    monkeypatch.setattr(pr, "materialise_worktree",
                        lambda p: ("", pr._Refusal(
                            "worktree prd-3/fix/x is dirty -- refusing to reset it", persistent=True)))
    called = []
    monkeypatch.setattr(pr, "sh_err", lambda *a, **k: called.append(a) or ("", "", 0))
    ok, detail, record = pr.dispatch(_pr(3), "failing", "x", dry=False)
    assert (ok, record) == (False, True)
    assert "dirty" in detail
    assert not called, "nothing must be spawned when the worktree could not be materialised"


def test_a_TRANSIENT_worktree_failure_is_not_recorded(monkeypatch, tmp_path):
    """A failed fetch / git-probe timeout clears on its own, so it must NOT buy a 45-min cooldown.

    It also must not eat a class slot for the rest of the pass -- `pass_budgets` charges the row on
    the NEXT pass, so charging `spent` here too would starve the other PRs in this one.
    """
    monkeypatch.setattr(pr, "STATE_DIR", str(tmp_path))
    monkeypatch.setattr(pr, "log", lambda m: None)
    monkeypatch.setattr(pr, "worker_status", lambda name: "lost")
    monkeypatch.setattr(pr, "materialise_worktree",
                        lambda p: ("", "cannot materialise fix/x: origin/fix/x could not be "
                                        "fetched (boom)"))
    monkeypatch.setattr(pr, "sh_err", lambda *a, **k: ("", "", 0))
    ok, detail, record = pr.dispatch(_pr(3), "failing", "x", dry=False)
    assert (ok, record) == (False, False), (ok, detail, record)


def test_main_writes_no_state_row_for_a_refused_spawn(monkeypatch):
    saved = {}
    monkeypatch.setattr(pr, "load_state", lambda: {})
    monkeypatch.setattr(pr, "open_prs", lambda: [_pr(1)])
    monkeypatch.setattr(pr, "classify", lambda p: "failing")
    monkeypatch.setattr(pr, "brief", lambda p, a: "b")
    monkeypatch.setattr(pr, "log", lambda m: None)
    monkeypatch.setattr(pr, "worker_status", lambda name: "failed")
    monkeypatch.setattr(pr, "dispatch", lambda p, a, t, d: (False, "gate refused rc=75", False))
    monkeypatch.setattr(pr, "save_state", lambda st: saved.update(st))
    monkeypatch.setattr(sys, "argv", ["pr-doctor.py"])
    monkeypatch.setenv("MAX_FIX", "16")
    monkeypatch.setenv("MAX_REVIEW", "12")
    assert pr.main() == 0
    assert not [k for k in saved if not k.startswith("_")], \
        "a refused spawn must not consume a state row / budget slot"


def test_main_writes_a_state_row_for_a_persistent_refusal(monkeypatch):
    """A refusal that will NOT clear on its own must reach a cooldown, not be retried for ever."""
    saved = {}
    monkeypatch.setattr(pr, "load_state", lambda: {})
    monkeypatch.setattr(pr, "open_prs", lambda: [_pr(1)])
    monkeypatch.setattr(pr, "classify", lambda p: "failing")
    monkeypatch.setattr(pr, "brief", lambda p, a: "b")
    monkeypatch.setattr(pr, "log", lambda m: None)
    monkeypatch.setattr(pr, "worker_status", lambda name: "lost")
    monkeypatch.setattr(pr, "dispatch",
                        lambda p, a, t, d: (False, "worktree dirty -- refusing", True))
    monkeypatch.setattr(pr, "save_state", lambda st: saved.update(st))
    monkeypatch.setattr(sys, "argv", ["pr-doctor.py"])
    monkeypatch.setenv("MAX_FIX", "16")
    monkeypatch.setenv("MAX_REVIEW", "12")
    assert pr.main() == 0
    assert saved.get("1", {}).get("head") == "a" * 40, "a persistent refusal must record a row"
    assert saved["1"]["kind"] == "refused", \
        "a refusal row must be stamped `refused`, or void_refused_rows will delete it on the next pass"


def test_dispatch_reports_a_failed_worktree_instead_of_spawning(monkeypatch, tmp_path):
    monkeypatch.setattr(pr, "STATE_DIR", str(tmp_path))
    monkeypatch.setattr(pr, "log", lambda m: None)
    monkeypatch.setattr(pr, "worker_status", lambda name: "lost")
    monkeypatch.setattr(pr, "materialise_worktree",
                        lambda p: ("", "worktree add failed rc=1: boom"))
    called = []
    monkeypatch.setattr(pr, "sh_err", lambda *a, **k: called.append(a) or ("", "", 0))
    ok, detail, _ = pr.dispatch(_pr(3), "failing", "x", dry=False)
    assert ok is False
    assert "worktree add failed" in detail
    assert not called, "nothing must be spawned when the worktree could not be materialised"


def test_nonblocking_dispatch_routes_through_run_agent(tmp_path):
    """Drive the REAL `nonblocking-dispatch.sh` against a stub `spawn-gate.sh`.

    A background dispatcher that carried its own spawn would never reach `run_agent()`. This
    asserts the call ARRIVES at the gate -- which is where the load gate lives -- by recording it.
    If the routing is ever "simplified" back to a direct `pi` spawn, this goes RED.

    ⛔ AND IT PINS THE OTHER HALF OF THE P0: the stub worker SLEEPS 3 s, so a CAPTURED call can only
    return promptly if the worker subshell closed the parent's stdout/stderr (`exec >/dev/null
    2>&1`). Without that line this test takes the worker's lifetime; measured pre-fix, 5.02 s for a
    5 s worker. Removing the `exec` from the harness reddens THIS test and nothing else, which is
    the point: pr-doctor no longer captures, so no shipped pr-doctor caller would notice.
    """
    d = tmp_path / "orch"
    d.mkdir()
    marker = tmp_path / "marker.txt"
    (d / "spawn-gate.sh").write_text(
        'run_agent() { echo "GATED $*" > "$MARK"; sleep 3; echo ran; return 0; }\n')
    wt = tmp_path / "wt"
    wt.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=str(wt), check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    prompt = tmp_path / "brief.txt"
    prompt.write_text("do the thing\n")
    env = dict(os.environ, O=str(d), MARK=str(marker))
    nb = _HARNESS / "nonblocking-dispatch.sh"
    t0 = time.monotonic()
    r = subprocess.run(["bash", str(nb), "prd-1", str(wt), str(prompt), "5"],
                       capture_output=True, text=True, env=env, timeout=30)
    elapsed = time.monotonic() - t0
    assert r.returncode == 0, r.stderr
    assert elapsed < 2.0, ("the captured call waited %.2fs for a 3 s worker -- the worker "
                           "subshell is holding the caller's pipe" % elapsed)
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
            return True, "", False
    monkeypatch.setattr(pr, "dispatch", dispatch)
    monkeypatch.setattr(pr, "worker_status", lambda name: "lost")
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


# ── 6. the spawn path RETURNS, and one PR never gets two workers ─────────────────────────
#
# Every test below drives the REAL `nonblocking-dispatch.sh` against a stub `spawn-gate.sh`, so the
# thing under test is the shipped dispatcher plus pr-doctor -- not a stub of either. Each one fails
# on e49fac32a; the pre-fix behaviour is named in its docstring.

# `run_agent` bodies, one per shape of worker the finding names.
# ⛔ EVERY ONE of these must OUTLIVE the assertion window (6 s vs a 3 s bound), or it cannot
# distinguish the defect: a worker that exits at once closes its own end of the pipe, so even a
# captured pre-fix call returned promptly for that shape.
_WORKERS = {
    # silent for its whole life
    "sleeps past the window and writes nothing": "run_agent() { sleep 6; return 0; }\n",
    # writes IMMEDIATELY (the shape where a caller with a pipe receives output first) and runs on
    "writes at once, then sleeps": 'run_agent() { echo starting; sleep 6; return 0; }\n',
    # writes to BOTH streams at the end
    "sleeps, then writes to stdout and stderr": 'run_agent() { sleep 6; echo OUT; echo ERR >&2; }\n',
}


def _orch(tmp_path, run_agent_body):
    """A private `$O` with a stub `spawn-gate.sh`, and a real git worktree to run in."""
    d = tmp_path / "orch"
    d.mkdir(parents=True, exist_ok=True)
    (d / "spawn-gate.sh").write_text(run_agent_body)
    wt = tmp_path / "wt"
    wt.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=str(wt), check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return d, wt


def _wire_dispatch(monkeypatch, tmp_path, d, wt):
    monkeypatch.setattr(pr, "STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(pr, "ORCH_DIR", str(d))
    monkeypatch.setattr(pr, "NONBLOCKING_DISPATCH", str(_HARNESS / "nonblocking-dispatch.sh"))
    monkeypatch.setattr(pr, "materialise_worktree", lambda p: (str(wt), ""))
    monkeypatch.setattr(pr, "log", lambda m: None)
    monkeypatch.setenv("O", str(d))


def _stub_the_spawn(monkeypatch, rc_ok=False):
    """Stub ONLY the spawn call (and record its argv), so the real git probes still run.

    `rc_ok` writes the worker's exit status the way `nonblocking-dispatch.sh` does, so the
    confirmation step sees a launch instead of an absent artifact.
    """
    seen = []
    real = pr.sh_err

    def fake(argv, timeout=180, cwd=None, env=None, capture=True):
        if "--status" not in argv and "nonblocking-dispatch.sh" in str(argv[1] if len(argv) > 1 else ""):
            seen.append(argv)
            if rc_ok:
                bg = pathlib.Path(pr.ORCH_DIR) / "bg"
                bg.mkdir(parents=True, exist_ok=True)
                (bg / (argv[2] + ".rc")).write_text("0\n")
            return "", "", 0
        return real(argv, timeout=timeout, cwd=cwd, env=env, capture=capture)

    monkeypatch.setattr(pr, "sh_err", fake)
    return seen


@pytest.mark.parametrize("label", sorted(_WORKERS))
def test_dispatch_returns_promptly_whatever_the_worker_does(monkeypatch, tmp_path, label):
    """P0: the dispatch call must END WITH THE DISPATCHER, not with the worker.

    PRE-FIX (`sh_err(spawn_argv(...), timeout=120)` with `capture_output=True`): `subprocess.run`
    blocks on EOF of the capture pipe, and the worker subshell inherits it -- so this call lasted
    the worker's whole life. For the sleeping worker that is 6 s here and TimeoutExpired at
    timeout=120 in production, which returned rc=-1, logged `FAIL`, and wrote NO state row.
    """
    d, wt = _orch(tmp_path, _WORKERS[label])
    _wire_dispatch(monkeypatch, tmp_path, d, wt)
    t0 = time.monotonic()
    ok, detail, record = pr.dispatch(_pr(5), "failing", "brief", dry=False)
    elapsed = time.monotonic() - t0
    assert ok is True and record is True, (ok, detail)
    assert elapsed < 3.0, "dispatch took %.2fs -- it waited for the worker" % elapsed


def test_a_worker_that_outlives_the_pass_still_writes_a_state_row(monkeypatch, tmp_path):
    """P0: the state row is what stops the next pass re-spawning everything.

    PRE-FIX: the 2400 s brief meant `sh_err` always hit `timeout=120`, so `dispatch()` returned
    False, `main()` logged `#N: not spawned` and wrote NO row -- no cooldown, no budget consumed,
    every later pass re-spawning every actionable PR.
    """
    saved = {}
    d, wt = _orch(tmp_path, "run_agent() { sleep 6; return 0; }\n")
    _wire_dispatch(monkeypatch, tmp_path, d, wt)
    monkeypatch.setattr(pr, "load_state", lambda: {})
    monkeypatch.setattr(pr, "open_prs", lambda: [_pr(5)])
    monkeypatch.setattr(pr, "classify", lambda p: "failing")
    monkeypatch.setattr(pr, "brief", lambda p, a: "b")
    monkeypatch.setattr(pr, "save_state", lambda st: saved.update(st))
    monkeypatch.setattr(sys, "argv", ["pr-doctor.py"])
    monkeypatch.setenv("MAX_FIX", "16")
    monkeypatch.setenv("MAX_REVIEW", "12")
    assert pr.main() == 0
    row = saved.get("5") or {}
    assert row.get("head") == "a" * 40 and row.get("worker") == "prd-5", \
        "a launched worker must consume a state row / cooldown: %r" % (saved,)
    assert row.get("kind") == "spawn", "a launched worker's row must be a spawn row"


def _artifacts(d):
    return {s: (d / "bg" / ("prd-7." + s)).read_bytes()
            for s in ("pid", "log", "started", "rc") if (d / "bg" / ("prd-7." + s)).exists()}


def test_a_live_worker_is_never_spawned_over(monkeypatch, tmp_path):
    """P1: a second spawn would DESTROY the live worker's log, `.rc` and `.pid`.

    `nonblocking-dispatch.sh` starts with `rm -f "$RC"`, `: > "$LOG"`, `echo … > "$PIDF"`, and the
    worker name (`prd-<n>`) and its worktree are deterministic -- so a second dispatch runs in the
    same directory and overwrites all three. PRE-FIX: `dispatch()` never asked, so two consecutive
    calls both returned True with pid2 in the pid file while pid1 was alive.
    """
    # 30 s, not 6: the assertion is about the SECOND dispatch, so the first worker must still be
    # alive however slow the runner is (nothing waits on it -- it is disowned by the harness).
    d, wt = _orch(tmp_path, "run_agent() { sleep 30; return 0; }\n")
    _wire_dispatch(monkeypatch, tmp_path, d, wt)
    ok1, detail1, record1 = pr.dispatch(_pr(7), "failing", "brief", dry=False)
    assert ok1 is True and record1 is True, detail1
    before = _artifacts(d)
    assert "pid" in before and "log" in before, before
    ok2, detail2, record2 = pr.dispatch(_pr(7), "failing", "other brief", dry=False)
    assert (ok2, record2) == (False, False), "a live worker must not be spawned over"
    assert "still running" in detail2
    assert _artifacts(d) == before, "the live worker's pid/log/rc must be untouched"


def test_a_head_change_does_not_bypass_the_live_worker_guard(monkeypatch):
    """P1: the reported trigger -- worker A pushes at T+2min, the pass at T+3min sees a NEW head.

    `prev.head != headRefOid` bypasses the cooldown by design, and `_ensure_head` is a no-op for a
    worker that pushed. PRE-FIX: `main()` called `dispatch()` and the second worker landed on top
    of the first. The guard must hold REGARDLESS of head movement.
    """
    calls = []
    st = {"7": {"action": "failing", "worker": "prd-7", "head": "b" * 40,
                "at": "2026-01-01T00:00:00Z", "at_epoch": 0}}
    monkeypatch.setattr(pr, "load_state", lambda: dict(st))
    monkeypatch.setattr(pr, "open_prs", lambda: [_pr(7)])
    monkeypatch.setattr(pr, "classify", lambda p: "failing")
    monkeypatch.setattr(pr, "brief", lambda p, a: "b")
    monkeypatch.setattr(pr, "log", lambda m: None)
    monkeypatch.setattr(pr, "worker_status", lambda name: "running")   # prd-7 is alive
    monkeypatch.setattr(pr, "dispatch", lambda p, a, t, d: calls.append(p["number"]) or (True, "", True))
    monkeypatch.setattr(pr, "save_state", lambda st2: None)
    monkeypatch.setattr(sys, "argv", ["pr-doctor.py"])
    monkeypatch.setenv("MAX_FIX", "16")
    monkeypatch.setenv("MAX_REVIEW", "12")
    assert pr.main() == 0
    assert calls == [], "a live worker must be in flight, not a free slot"


def test_materialise_adopts_a_worktree_the_pr_branch_is_already_in(monkeypatch, tmp_path):
    """P1: a PR produced by a lane has its branch in THAT LANE'S worktree -- the normal case.

    `git worktree add <path> <branch>` refuses to check one branch out twice (rc=128 "'fix/abc' is
    already used by worktree at …"), and merging the PR is what frees the worktree, so refusing
    deadlocks. PRE-FIX: `materialise_worktree` returned ("", "worktree add failed rc=128: …"), and
    `dispatch()` then returned False with no state row -- one log line per pass, for ever.
    """
    repo, g = _git_repo(tmp_path)
    head = g("rev-parse", "HEAD").stdout.strip()
    g("branch", "fix/abc")
    lane = repo / ".worktrees" / "fix-1529"
    g("worktree", "add", str(lane), "fix/abc")
    _wire_repo(monkeypatch, repo)
    wt, err = pr.materialise_worktree(_prb(42, head, "fix/abc"))
    assert err == "", err
    assert os.path.realpath(wt) == os.path.realpath(str(lane)), \
        "the PR's own branch worktree must be adopted, not refused"
    assert subprocess.run(["git", "-C", wt, "symbolic-ref", "--short", "HEAD"],
                          capture_output=True, text=True).stdout.strip() == "fix/abc"


def test_adopting_an_unsafe_lane_worktree_refuses_AND_records_a_row(monkeypatch, tmp_path):
    """P1: when adoption is UNSAFE the refusal must reach a cooldown, not retry for ever.

    The lane worktree on the PR's branch holds uncommitted work at a different head, so it may be
    neither reset nor ignored. PRE-FIX: `materialise_worktree` failed on `worktree add` and
    `dispatch()` returned a bare False -- no row, so the pass re-attempted it every cycle and the
    PR never appeared in `--status`.
    """
    repo, g = _git_repo(tmp_path)
    c1 = g("rev-parse", "HEAD").stdout.strip()
    g("branch", "fix/abc")
    lane = repo / ".worktrees" / "fix-1529"
    g("worktree", "add", str(lane), "fix/abc")
    g("commit", "--allow-empty", "-qm", "second")          # PR head moves on main
    c2 = g("rev-parse", "HEAD").stdout.strip()
    (lane / "f.txt").write_text("a lane's uncommitted work\n")   # tracked -> dirty
    _wire_repo(monkeypatch, repo)
    monkeypatch.setattr(pr, "STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(pr, "worker_status", lambda name: "lost")
    _stub_the_spawn(monkeypatch)
    ok, detail, record = pr.dispatch(_prb(42, c2, "fix/abc"), "failing", "brief", dry=False)
    assert (ok, record) == (False, True), (ok, detail, record)
    assert "uncommitted" in detail and str(lane) in detail, detail
    assert (lane / "f.txt").read_text() == "a lane's uncommitted work\n", \
        "the lane's work must never be reset (c1=%s)" % c1[:7]


def test_an_adopted_lane_worktree_at_the_pr_head_is_dispatched(monkeypatch, tmp_path):
    """The other half of adoption: a CLEAN lane worktree at the PR head runs the worker."""
    repo, g = _git_repo(tmp_path)
    head = g("rev-parse", "HEAD").stdout.strip()
    g("branch", "fix/abc")
    lane = repo / ".worktrees" / "fix-1529"
    g("worktree", "add", str(lane), "fix/abc")
    _wire_repo(monkeypatch, repo)
    monkeypatch.setattr(pr, "STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(pr, "worker_status", lambda name: "lost")
    monkeypatch.setattr(pr, "CONFIRM_WINDOW_S", 0.5)
    seen = _stub_the_spawn(monkeypatch, rc_ok=True)
    ok, detail, record = pr.dispatch(_prb(42, head, "fix/abc"), "failing", "brief", dry=False)
    assert ok is True and record is True, detail
    assert seen and os.path.realpath(seen[-1][3]) == os.path.realpath(str(lane)), seen


# ── 7. a partial exit-status write is NOT a verdict ──────────────────────────────────────

def test_read_rc_ignores_a_partial_write(tmp_path):
    """P3: `int(fh.read().strip())` accepted `7` -- the first byte of `75\\n` -- as the code 7.

    `7` is not a refusal code, so dispatch() broke out of the poll and recorded as LAUNCHED a
    spawn the gate had REFUSED. A partial write is not a verdict: the code is accepted only when
    the trailing newline `echo` writes has arrived.
    """
    p = tmp_path / "x.rc"
    p.write_text("7")
    assert pr.read_rc(str(p)) is None
    p.write_text("75")
    assert pr.read_rc(str(p)) is None
    p.write_text("75\n")
    assert pr.read_rc(str(p)) == 75
    assert pr.read_rc(str(tmp_path / "absent.rc")) is None


def test_a_refusal_split_across_two_writes_is_finally_read(monkeypatch, tmp_path):
    """End-to-end P3: the code lands in two chunks WHILE dispatch() is polling.

    PRE-FIX: the first read saw `7`, `int()` accepted it, `7 not in (75, 77)` broke the loop, and
    dispatch() returned True -- a recorded dispatch for a spawn the gate had refused.
    """
    d, wt = _orch(tmp_path, "run_agent() { return 0; }\n")
    _wire_dispatch(monkeypatch, tmp_path, d, wt)
    rc = d / "bg" / "prd-8.rc"
    rc.parent.mkdir(parents=True, exist_ok=True)
    rc.write_text("7")                          # the first chunk of `echo 75` has landed
    (d / "bg" / "prd-8.log").write_text("[load-gate] REFUSED bg prd-8: load=99 >= max_load=40\n")
    threading.Timer(0.4, lambda: rc.write_text("75\n")).start()

    def fake_sh_err(argv, timeout=180, cwd=None, env=None, capture=True):
        if "--status" in argv:
            return "prd-8 lost (no exit status recorded and pid is gone)\n", "", 0
        return "", "", 0

    monkeypatch.setattr(pr, "sh_err", fake_sh_err)
    monkeypatch.setattr(pr, "CONFIRM_WINDOW_S", 2.0)
    ok, detail, record = pr.dispatch(_pr(8), "failing", "brief", dry=False)
    assert (ok, record) == (False, False), (ok, detail, record)
    assert "75" in detail


def test_a_row_left_by_a_refused_spawn_is_reclaimed_on_the_next_pass(tmp_path, monkeypatch):
    """P2: the durable backstop. A refusal that lands AFTER the confirmation window must not hold
    a cooldown and a class slot for STALE_DISPATCH_S (90 min) -- the next pass re-reads the same
    `.rc` artifact and drops the row. PRE-FIX: no window check existed at all, so the row stood."""
    d = tmp_path / "orch"
    (d / "bg").mkdir(parents=True)
    (d / "bg" / "prd-4.rc").write_text("75\n")
    (d / "bg" / "prd-4.log").write_text("[load-gate] REFUSED bg prd-4: load=99 >= max_load=40\n")
    monkeypatch.setattr(pr, "ORCH_DIR", str(d))
    st = {"4": {"action": "failing", "worker": "prd-4", "kind": "spawn", "head": "a" * 40,
                "at": "2026-01-01T00:00:00Z", "at_epoch": 0}}
    assert pr.void_refused_rows(st) == ["4"]
    assert "4" not in st
    assert pr.pass_budgets(st, {"max_fix": 1, "max_review": 1})["fix"] == 1, \
        "the reclaimed slot must be usable again"


def test_a_worktree_refusal_row_is_NOT_voided_by_a_stale_rc(tmp_path, monkeypatch):
    """A `kind: refused` row owns no `.rc`, so an EARLIER worker's 75 must not delete it.

    The row exists because the worktree refusal will not clear by waiting; if the stale artifact
    voided it, the cooldown would never hold, the pass would re-probe every cycle and log the same
    line for ever -- the exact loop the record exists to close.
    """
    d = tmp_path / "orch"
    (d / "bg").mkdir(parents=True)
    (d / "bg" / "prd-6.rc").write_text("75\n")                     # left by an EARLIER attempt
    (d / "bg" / "prd-6.log").write_text("[load-gate] REFUSED bg prd-6\n")
    monkeypatch.setattr(pr, "ORCH_DIR", str(d))
    st = {"6": {"action": "failing", "worker": "prd-6", "kind": "refused", "head": "a" * 40,
                "at": "2026-01-01T00:00:00Z", "at_epoch": 0}}
    assert pr.void_refused_rows(st) == []
    assert st["6"]["kind"] == "refused", "the row must survive, or the cooldown never holds"


def test_a_row_is_kept_when_the_rc_came_from_pi_not_the_gate(tmp_path, monkeypatch):
    """`pi` shares the 0-255 namespace: rc=75 with NO gate marker is an agent that RAN and failed.

    Dropping that row would re-dispatch a PR whose worker really executed (bypassing its
    cooldown); keeping it is what the `[load-gate] REFUSED` marker buys.
    """
    d = tmp_path / "orch"
    (d / "bg").mkdir(parents=True)
    (d / "bg" / "prd-9.rc").write_text("75\n")
    (d / "bg" / "prd-9.log").write_text("[timeout] agent pid=42 wall_limit=2400s elapsed=9s rc=75\n")
    monkeypatch.setattr(pr, "ORCH_DIR", str(d))
    assert pr.gate_refused("prd-9", 75) is False
    st = {"9": {"action": "failing", "worker": "prd-9", "kind": "spawn", "head": "a" * 40,
                "at": "2026-01-01T00:00:00Z", "at_epoch": 0}}
    assert pr.void_refused_rows(st) == []


def test_the_refusal_markers_are_the_gates_own_lines():
    """Anti-drift on the ONE piece of prose this file reads: reword it in spawn-gate.sh and the
    refusal detection silently stops working (every refusal would read as a real dispatch)."""
    gate = (_HARNESS / "spawn-gate.sh").read_text()
    for marker in pr.REFUSAL_MARKERS:
        assert 'echo "%s ' % marker in gate, \
            "spawn-gate.sh no longer writes %r -- REFUSAL_MARKERS is stale" % marker


def test_an_unreadable_worker_status_REFUSES_to_spawn(monkeypatch, tmp_path):
    """`None` is not "free to spawn": a blind second spawn destroys a live worker's .log/.rc/.pid."""
    monkeypatch.setattr(pr, "STATE_DIR", str(tmp_path))
    monkeypatch.setattr(pr, "log", lambda m: None)
    monkeypatch.setattr(pr, "worker_status", lambda name: None)      # --status unanswerable
    spawned = []
    monkeypatch.setattr(pr, "sh_err", lambda *a, **k: spawned.append(a) or ("", "", 0))
    ok, detail, record = pr.dispatch(_pr(12), "failing", "x", dry=False)
    assert (ok, record) == (False, False)
    assert "liveness" in detail
    assert not spawned, "nothing may be spawned when liveness cannot be read"


def test_a_recycled_pid_is_not_a_live_worker(tmp_path, monkeypatch):
    """`--status` answers `running` from `kill -0` on an unpruned pid file; the harness's own
    `.started` stamp bounds it, or a recycled pid would skip that PR for ever."""
    d = tmp_path / "orch"
    (d / "bg").mkdir(parents=True)
    (d / "bg" / "prd-2.started").write_text("name=prd-2\n")
    monkeypatch.setattr(pr, "ORCH_DIR", str(d))
    monkeypatch.setattr(pr, "log", lambda m: None)
    monkeypatch.setattr(pr, "worker_status", lambda name: "running")
    assert pr.worker_live("prd-2") is True                       # fresh stamp, live pid
    old = time.time() - (pr.SPAWN_TIMEOUT_S + pr.WORKER_STALE_SLACK_S + 60)
    os.utime(str(d / "bg" / "prd-2.started"), (old, old))
    assert pr.worker_live("prd-2") is False, "a stamp older than cap+slack is a recycled pid"


def test_a_dispatcher_failure_reports_the_dispatchers_own_stderr(monkeypatch, tmp_path):
    """The harness's stderr is the ONLY channel for a permanent misconfiguration.

    `nonblocking-dispatch.sh` refuses with `exit 78` + a message on stderr when it cannot find
    `spawn-gate.sh`. Routing stderr to DEVNULL (or to a pipe, the P0) either loses that text or
    blocks; it goes to a temp file, so the log line names the real cause. This runs the shipped
    harness with no `spawn-gate.sh` anywhere it looks.
    """
    d = tmp_path / "orch"
    d.mkdir()
    nb = d / "nonblocking-dispatch.sh"
    nb.write_bytes((_HARNESS / "nonblocking-dispatch.sh").read_bytes())   # no sibling gate
    wt = tmp_path / "wt"
    wt.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=str(wt), check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    monkeypatch.setattr(pr, "STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(pr, "ORCH_DIR", str(d))
    monkeypatch.setattr(pr, "NONBLOCKING_DISPATCH", str(nb))
    monkeypatch.setattr(pr, "materialise_worktree", lambda p: (str(wt), ""))
    monkeypatch.setattr(pr, "worker_status", lambda name: "lost")
    monkeypatch.setattr(pr, "log", lambda m: None)
    ok, detail, record = pr.dispatch(_pr(13), "failing", "brief", dry=False)
    assert (ok, record) == (False, False)
    assert "78" in detail and "spawn-gate.sh" in detail, detail


def test_main_persists_a_voided_row_without_dispatching_anything(monkeypatch, tmp_path):
    """The void must be WRITTEN, not merely logged: the helper drops the row in memory, and every
    early return after it (`no open PRs`, `no budget`) used to skip `save_state` -- so the log
    claimed a drop that no later pass would see."""
    d = tmp_path / "orch"
    (d / "bg").mkdir(parents=True)
    (d / "bg" / "prd-3.rc").write_text("77\n")
    (d / "bg" / "prd-3.log").write_text("[disk-gate] REFUSED bg prd-3: only 10MB free\n")
    monkeypatch.setattr(pr, "ORCH_DIR", str(d))
    monkeypatch.setattr(pr, "log", lambda m: None)
    monkeypatch.setattr(pr, "load_state",
                        lambda: {"3": {"action": "failing", "worker": "prd-3", "kind": "spawn",
                                       "head": "a" * 40, "at": "2026-01-01T00:00:00Z",
                                       "at_epoch": 0}})
    saved = {}
    monkeypatch.setattr(pr, "save_state", lambda st: saved.update({k: dict(v) for k, v in st.items()}))
    monkeypatch.setattr(pr, "open_prs", lambda: [])          # the early-return path
    monkeypatch.setattr(sys, "argv", ["pr-doctor.py"])
    assert pr.main() == 0
    assert "3" not in saved, "the refused row must be dropped AND persisted: %r" % (saved,)


def test_main_shows_a_refused_row_as_refused_in_status(monkeypatch, capsys):
    """`--status` is the operator's verb: a row that exists because the PR was REFUSED must not
    read as a dispatch."""
    monkeypatch.setattr(pr, "load_state",
                        lambda: {"7": {"action": "failing", "worker": "prd-7", "kind": "refused",
                                       "head": "a" * 40, "at": "2026-01-01T00:00:00Z",
                                       "at_epoch": 0},
                                 "8": {"action": "ready", "worker": "prd-8", "kind": "spawn",
                                       "head": "b" * 40, "at": "2026-01-01T00:00:00Z",
                                       "at_epoch": 0}})
    monkeypatch.setattr(sys, "argv", ["pr-doctor.py", "--status"])
    assert pr.main() == 0
    out = capsys.readouterr().out
    assert "kind=refused" in out
    assert "kind=spawn" not in out, "a real dispatch must print exactly what it always did"


def test_an_agents_own_output_cannot_forge_a_refusal(tmp_path, monkeypatch):
    """The worker log is shared with the AGENT. A `pi` that prints the marker and then exits 75
    must be read as "an agent ran and failed", not as a gate refusal -- otherwise its row is
    deleted and the PR is re-dispatched on top of work that really happened."""
    d = tmp_path / "orch"
    (d / "bg").mkdir(parents=True)
    # ⛔ THE PRODUCER'S ORDER, not a convenient one: `spawn-gate.sh` starts `pi >> $LOG` and writes
    # the `[timeout] agent pid=` line only AFTER `wait`, so an agent's output sits ABOVE it. A
    # fixture that puts the marker FIRST would pass against a code that splits on it, which is how
    # an inverted discriminator survived a "fix" once already.
    (d / "bg" / "prd-4.log").write_text(
        'the reviewer quoted the literal "[load-gate] REFUSED" marker\n'
        "[timeout] agent pid=42 wall_limit=2400s elapsed=61s rc=75\n")
    (d / "bg" / "prd-4.rc").write_text("75\n")
    monkeypatch.setattr(pr, "ORCH_DIR", str(d))
    assert pr.gate_refused("prd-4", 75) is False
    st = {"4": {"action": "failing", "worker": "prd-4", "kind": "spawn", "head": "a" * 40,
                "at": "2026-01-01T00:00:00Z", "at_epoch": 0}}
    assert pr.void_refused_rows(st) == [], "a ran-and-failed worker keeps its cooldown"


def test_a_large_worker_log_is_evidence_an_agent_ran(tmp_path, monkeypatch):
    """Only an agent writes a big log; the gate refuses in a line. Past the read window the answer
    must be "an agent ran" (keep the cooldown), never "nothing consumed"."""
    d = tmp_path / "orch"
    (d / "bg").mkdir(parents=True)
    (d / "bg" / "prd-5.log").write_text('x\n' * (pr.REFUSAL_LOG_WINDOW // 2 + 10)
                                       + "[load-gate] REFUSED quoted by the agent\n")
    (d / "bg" / "prd-5.rc").write_text("75\n")
    monkeypatch.setattr(pr, "ORCH_DIR", str(d))
    assert pr.gate_refused("prd-5", 75) is False


def test_the_agent_ran_marker_is_still_written_after_the_wait():
    """`gate_refused` keys on `[timeout] agent pid=` meaning "an agent ran". If spawn-gate.sh stops
    writing it -- or writes it BEFORE the agent is waited on -- every refusal-vs-run distinction
    silently degrades to "refusal".

    ⛔ ANCHORED ON THE COMMAND, NOT ON A SUBSTRING. `gate.index("wait ")` finds the FIRST `wait `
    in the file, and that is a word in a comment (spawn-gate.sh's disk-gate rationale), not
    `wait "$pid"` -- so a substring assertion is satisfied by prose and stays green when the real
    `wait` is deleted. Line numbers are compared instead.
    """
    lines = gate_lines()
    wait_ln = [i for i, l in enumerate(lines, 1) if re.match(r'^\s*wait\s+"\$pid"', l)]
    marker_ln = [i for i, l in enumerate(lines, 1) if pr.AGENT_RAN_MARKER in l]
    assert wait_ln, "spawn-gate.sh no longer waits on the agent pid"
    assert marker_ln, "spawn-gate.sh no longer writes %r" % pr.AGENT_RAN_MARKER
    assert min(marker_ln) > min(wait_ln), \
        "the [timeout] marker must be written AFTER `wait`, or presence stops meaning 'ran'"
    # ...and every refusal verdict is written BEFORE `pi` is launched, which is the other half of
    # the discriminator: a gate line and a launch cannot both be true of one run.
    launch_ln = [i for i, l in enumerate(lines, 1) if l.strip().startswith("pi -p")]
    assert launch_ln, "spawn-gate.sh no longer launches the agent with `pi -p`"
    for marker in pr.REFUSAL_MARKERS:
        for i, l in enumerate(lines, 1):
            if marker in l and l.lstrip().startswith("echo"):
                assert i < min(launch_ln), "%r must be written BEFORE the agent starts" % marker


def gate_lines():
    return (_HARNESS / "spawn-gate.sh").read_text().splitlines()
