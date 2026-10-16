#!/usr/bin/env python3
"""Proof that pr-doctor's dispatch cap is the MACHINE's, never a private literal.

WHY THIS FILE EXISTS. `scripts/pr-doctor.py` hardcoded `MAX_INFLIGHT = 4` "fleet-wide" while the
box that runs it is configured for `MAX_FIX=16` / `MAX_REVIEW=12`. The PR chain -- the path that
drains the backlog -- was therefore throttled to 4, and because the launch job passes no `--max`
there was no way to override it from config. Measured 2026-10-16: the same queue dispatched 0 at
the hardcoded cap and `prd-8797 -> OK` at `--max 12`, in the same minute on the same fleet.

The rule these tests pin:
  * a threshold configured on the machine reaches the dispatch cap (per class), and
  * the fallback defaults are the SAME model `orch-loop.sh` resolves, and
  * a dispatch that failed to read the lanes prints a named blindness, never a silent zero.

Run:  <venv>/bin/python -m pytest test_pr_doctor.py -q
"""
from __future__ import annotations

import importlib.util
import pathlib
import re
import sys

import pytest

_REPO = pathlib.Path(__file__).resolve().parent.parent
_SPEC = importlib.util.spec_from_file_location(
    "pr_doctor_under_test", pathlib.Path(__file__).with_name("pr-doctor.py"))
pr = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(pr)


def _pr(number: int, head: str = "a" * 40) -> dict:
    return {"number": number, "title": "t%d" % number, "isDraft": False, "headRefOid": head,
            "headRefName": "b", "mergeStateStatus": "CLEAN", "files": []}


def _lane(n: int) -> dict:
    return {"lane": "lane-%d" % n, "ws": "ws-%d" % n, "verdict": "DONE-IDLE"}


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    """A test must never inherit the developer's or the CI runner's capacity env."""
    for k in ("MAX_FIX", "MAX_REVIEW"):
        monkeypatch.delenv(k, raising=False)
    # Point the plist at a path that cannot exist, so a sandbox that happens to have the
    # orchestrator installed does not leak its values into a unit test. `raising=False` keeps the
    # end-to-end cap test runnable against the PRE-fix file, so its failure is behavioural (4
    # dispatches, not 10) rather than an AttributeError.
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
    loop = (_REPO / "scripts" / "orchestrator-harness" / "orch-loop.sh").read_text()
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
    the ROOT too -- otherwise a corrupted or hand-edited plist aborts the whole pass (the
    pre-fix code never read the plist at all) instead of using the env/defaults.
    """
    import plistlib
    plist = tmp_path / "loop.plist"
    with open(plist, "wb") as f:
        plistlib.dump([{"Label": "com.eldato.orchestrator-loop"}], f)
    monkeypatch.setattr(pr, "ORCH_PLIST", str(plist))
    monkeypatch.setenv("MAX_FIX", "16")
    assert pr.capacity() == {"max_fix": 16, "max_review": pr.DEFAULT_MAX_REVIEW}


def test_orch_plist_path_is_pinned_to_install_sh_label():
    """The ONE home must not silently evaporate if the launchd label is renamed.

    `install.sh` owns the label; if it changes and pr-doctor's literal does not, `capacity()`
    reads a nonexistent file and falls back to 3/4 -- the exact regression this change removes --
    with the suite still green. Pin pr-doctor's literal to the installer's own `LABEL=`.
    (Read the source literal: the autouse fixture stubs the runtime path.)
    """
    src = (_REPO / "scripts" / "pr-doctor.py").read_text()
    lm = re.search(r'ORCH_PLIST = os\.path\.join\(HOME, "Library", "LaunchAgents", "([^"]+)"\)', src)
    assert lm, "pr-doctor.py no longer builds ORCH_PLIST from a literal plist name"
    inst = (_REPO / "scripts" / "orchestrator-harness" / "install.sh").read_text()
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


# ── 3. the end-to-end dispatch cap is the configured one, not 4 ───────────────────────────

def _drive(monkeypatch, *, prs, action, cap_env, lanes=40):
    """Run one dry pass with a stubbed world and return the dispatch labels it emitted."""
    sent = []
    monkeypatch.setattr(pr, "load_state", lambda: {})
    monkeypatch.setattr(pr, "open_prs", lambda: list(prs))
    monkeypatch.setattr(pr, "classify", lambda p: action(p) if callable(action) else action)
    monkeypatch.setattr(pr, "brief", lambda p, a: "brief-%s" % p["number"])
    monkeypatch.setattr(pr, "idle_lanes", lambda: ([_lane(i) for i in range(lanes)], ""))
    monkeypatch.setattr(pr, "log", lambda msg: None)
    monkeypatch.setattr(pr, "dispatch", lambda ws, label, text, dry: sent.append(label) or True)
    monkeypatch.setattr(sys, "argv", ["pr-doctor.py", "--dry-run"])
    monkeypatch.setenv("MAX_FIX", str(cap_env[0]))
    monkeypatch.setenv("MAX_REVIEW", str(cap_env[1]))
    assert pr.main() == 0
    return sent


def test_configured_capacity_reaches_the_dispatch_cap(monkeypatch):
    """The regression: the box is configured for 16/12, so 10 fix orders must all dispatch.

    On the old hardcoded `MAX_INFLIGHT = 4` this returns 4 labels; it fails before the fix and
    passes after.
    """
    sent = _drive(monkeypatch, prs=[_pr(n) for n in range(1, 11)],
                  action="failing", cap_env=(16, 12))
    assert len(sent) == 10


def test_fix_and_review_budgets_are_separate(monkeypatch):
    """The box distinguishes fix from review; pr-doctor must not collapse them into one cap."""
    prs = [_pr(n) for n in range(1, 11)]
    # 1..5 failing (fix), 6..10 unreviewed (review); ranked order puts unreviewed before failing.
    def classify(p):
        return "failing" if p["number"] <= 5 else "unreviewed"
    sent = _drive(monkeypatch, prs=prs, action=classify, cap_env=(2, 3))
    # 2 fix + 3 review = 5, even though 10 PRs are ready for work and 40 lanes are idle.
    assert len(sent) == 5
    fix = [s for s in sent if s in ("prd-1", "prd-2", "prd-3", "prd-4", "prd-5")]
    review = [s for s in sent if s in ("prd-6", "prd-7", "prd-8", "prd-9", "prd-10")]
    assert len(fix) == 2 and len(review) == 3


# ── 4. a failed lane read is a NAMED blindness, never a silent zero ──────────────────────

def test_failed_lane_read_names_the_blindness(monkeypatch, capsys):
    logs = []
    monkeypatch.setattr(pr, "load_state", lambda: {})
    monkeypatch.setattr(pr, "open_prs", lambda: [_pr(1)])
    monkeypatch.setattr(pr, "classify", lambda p: "failing")
    monkeypatch.setattr(pr, "idle_lanes",
                        lambda: ([], "lane-actions read failed rc=1: connection refused"))
    monkeypatch.setattr(pr, "log", logs.append)
    monkeypatch.setattr(pr, "dispatch",
                        lambda *a, **k: pytest.fail("dispatch must not run on a blind read"))
    monkeypatch.setattr(sys, "argv", ["pr-doctor.py", "--dry-run"])
    assert pr.main() == 0
    joined = "\n".join(logs)
    assert "LANE READ FAILED" in joined
    assert "connection refused" in joined
    # and it must NOT be reported as "there was nothing to do"
    assert "nothing dispatched this pass" not in joined
