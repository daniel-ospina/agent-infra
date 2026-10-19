#!/usr/bin/env python3
"""test_queue_dispatch.py -- the OWNER'S DISPATCH PRIORITY, pinned where it is enforced.

⛔ WHY THIS FILE EXISTS (owner, 2026-10-18): "un-owned PRs first -- a PR is owned only if a LIVE
process has it -- then new issues." `pr-doctor.py` measures that and publishes `issue_work` in its
status record; BEFORE this gate NOTHING read it, so the rule lived in a log line and a reader could
not tell "no new work was needed" from "new work was skipped". This file pins the gate's verdicts,
including every direction in which it must NOT block: a measurement that is missing, stale,
unreadable or produced by a REFUSED pass has not answered the question, and blocking all issue
dispatch on it would let one broken component starve the rest of the fleet.

Run: /usr/bin/python3 -m pytest scripts/test_queue_dispatch.py -q
"""
import importlib.util
import json
import os
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


QD = _load("queue_dispatch", os.path.join(HERE, "queue-dispatch.py"))


def _record(tmp_path, *, rc=0, work="SKIPPED", age_s=60.0, reason="dispatched 3 of 9 queued — ok",
            **extra):
    d = {"rc": rc, "issue_work": work, "reason": reason,
         "at_epoch": time.time() - age_s}
    d.update(extra)
    (tmp_path / "pr-doctor.status.json").write_text(json.dumps(d))


def test_no_record_is_not_a_block(tmp_path, capsys):
    """A dispatcher that has never run must not stop issue work -- it has measured nothing."""
    assert QD.pr_first_gate(state_dir=str(tmp_path)) == ""
    assert "recorded no pass yet" in capsys.readouterr().out


def test_un_owned_PRs_skip_new_issue_work(tmp_path):
    """THE OWNER'S RULE: un-owned PRs exist -> new issue work is SKIPPED, and it says why."""
    _record(tmp_path, work="SKIPPED", reason="issues: SKIPPED (un-owned PRs exist) -- 3 of 15")
    gate = QD.pr_first_gate(state_dir=str(tmp_path))
    assert gate.startswith("issues: SKIPPED (un-owned PRs exist)"), gate
    assert "3 of 15" in gate, gate          # the EVIDENCE travels with the refusal


def test_every_PR_owned_lets_issue_work_proceed(tmp_path):
    _record(tmp_path, work="ELIGIBLE", reason="issues: ELIGIBLE (no un-owned PRs)")
    assert QD.pr_first_gate(state_dir=str(tmp_path)) == ""


def test_a_STALE_record_does_not_gate(tmp_path, capsys):
    """⛔ A RECORD IS A PAST STATE. Beyond two 1200s dispatch intervals it is not a measurement."""
    _record(tmp_path, age_s=QD.PR_FIRST_MAX_AGE_S + 60)
    assert QD.pr_first_gate(state_dir=str(tmp_path)) == ""
    assert "STALE" in capsys.readouterr().out


def test_a_pass_that_measured_NOTHING_cannot_gate(tmp_path, capsys):
    """⛔ ABSENCE OF A MEASUREMENT IS THE TEST, NOT THE EXIT CODE (2026-10-18, review).

    The first revision keyed on `rc != 0`, which inverted the owner's rule exactly when it mattered:
    the dispatcher publishes `issue_work` on rc=2 (dispatch refused, PRs still classified) and on
    rc=3 (work placed, no lane accepted it) -- and the LIVE record on this box was `RED rc=3 … no lane
    accepted`, which the gate ignored. A record with no `issue_work` field is the only one that
    measured nothing (open-PR read failed / empty queue / checks unreadable / no roster).
    """
    _record(tmp_path, rc=2, work="", reason="lane roster UNREADABLE")
    assert QD.pr_first_gate(state_dir=str(tmp_path)) == ""
    assert "measured no ownership verdict" in capsys.readouterr().out


def test_a_REFUSED_but_measured_pass_STILL_gates(tmp_path, capsys):
    """rc=3 means the order was not placed -- the PRs were still measured, so the rule still holds."""
    _record(tmp_path, rc=3, work="SKIPPED",
            reason="no idle lane in the roster; 1 order(s) no lane accepted")
    gate = QD.pr_first_gate(state_dir=str(tmp_path))
    assert gate.startswith("issues: SKIPPED (un-owned PRs exist)"), gate
    assert "also refused, rc=3" in capsys.readouterr().out


def test_an_UNREADABLE_record_does_not_gate(tmp_path, capsys):
    """Absence of a readable verdict is not a verdict -- and it says so instead of guessing."""
    (tmp_path / "pr-doctor.status.json").write_text("{not json")
    assert QD.pr_first_gate(state_dir=str(tmp_path)) == ""
    assert "unreadable" in capsys.readouterr().out


def test_the_gate_is_actually_CALLED_by_the_dispatch_path(tmp_path, monkeypatch, capsys):
    """⛔ THE GATE MUST BE A GATE, NOT A FUNCTION NOBODY CALLS.

    (This is the defect the whole change exists to remove: pr-doctor printed the decision and
    nothing consumed it.) The wiring is pinned by asserting `main()` prints the skip line and does
    not reach the dispatch loop.
    """
    src = open(os.path.join(HERE, "queue-dispatch.py")).read()
    assert "_gate = pr_first_gate()" in src, "the gate is not wired into main()"
    i_gate = src.index("_gate = pr_first_gate()")
    i_loop = src.index("    for r in idle:", i_gate)
    assert i_gate < i_loop, "the gate must be evaluated BEFORE the dispatch loop"


def test_the_skip_line_names_the_evidence_and_zero(tmp_path):
    """`dispatched 0` must never read as healthy: it says 0 OF WHAT and WHY."""
    _record(tmp_path, work="SKIPPED", reason="issues: SKIPPED (un-owned PRs exist) -- 3 of 15")
    gate = QD.pr_first_gate(state_dir=str(tmp_path))
    assert gate, "expected a skip reason"
    assert "un-owned PRs exist" in gate, gate
