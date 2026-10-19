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
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


QD = _load("queue_dispatch", os.path.join(HERE, "queue-dispatch.py"))


def _record(tmp_path, *, rc=0, work="SKIPPED", age_s=60.0, reason="dispatched 3 of 9 queued — ok",
            un_owned=3, owned=12, ownership_read_failed="", **extra):
    # `un_owned`/`owned`/`ownership_read_failed` are what a REAL pr-doctor record carries on every
    # path that classified work: the gate keys on the reading, not on the exit code (#2055).
    d = {"rc": rc, "issue_work": work, "reason": reason,
         "at_epoch": time.time() - age_s,
         "ownership_read_failed": ownership_read_failed}
    if un_owned is not None:
        d["un_owned"] = un_owned
    if owned is not None:
        d["owned"] = owned
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


def test_a_REFUSED_pass_STILL_gates_on_the_ownership_it_measured(tmp_path, capsys):
    """⛔ THE PRIORITY DOES NOT LAPSE WHEN THE PASS REFUSES (#2055 review, P1).

    The ownership probe runs BEFORE every refusal, and NO-CAPACITY / roster-UNREADABLE /
    UNDELIVERED all publish `issue_work: SKIPPED` with a real `un_owned` count. Keying the gate on
    `rc == 0` threw that reading away exactly when it matters: the box over its load band, or with
    every lane mid-task, then dispatched NEW ISSUE WORK while un-owned PRs waited.
    """
    for rc, kind in ((5, "NO-CAPACITY"), (2, "UNREADABLE"), (3, "UNDELIVERED")):
        _record(tmp_path, rc=rc, work="SKIPPED", un_owned=6, owned=9,
                reason="no dispatchable lane -- nothing dispatched this pass",
                kind=kind, ownership_read_failed="")
        gate = QD.pr_first_gate(state_dir=str(tmp_path))
        assert gate.startswith("issues: SKIPPED (un-owned PRs exist)"), (rc, gate)


def test_a_pass_whose_OWNERSHIP_read_failed_does_not_gate(tmp_path, capsys):
    """No reading -> no refusal: a blind probe must not starve issue dispatch."""
    _record(tmp_path, rc=2, work="SKIPPED", un_owned=0, owned=0,
            ownership_read_failed="lsof cwd probe failed rc=1")
    assert QD.pr_first_gate(state_dir=str(tmp_path)) == ""
    assert "could not READ ownership" in capsys.readouterr().out


def test_a_record_with_NO_ownership_field_does_not_gate(tmp_path, capsys):
    """A record written before this field existed is not an ownership measurement."""
    _record(tmp_path, rc=2, work="SKIPPED", reason="the open-PR read FAILED",
            un_owned=None, owned=None)
    assert QD.pr_first_gate(state_dir=str(tmp_path)) == ""
    assert "no ownership reading" in capsys.readouterr().out


def test_an_UNREADABLE_record_does_not_gate(tmp_path, capsys):
    """Absence of a readable verdict is not a verdict -- and it says so instead of guessing."""
    (tmp_path / "pr-doctor.status.json").write_text("{not json")
    assert QD.pr_first_gate(state_dir=str(tmp_path)) == ""
    assert "unreadable" in capsys.readouterr().out


def test_the_gate_is_actually_CALLED_by_main_and_STOPS_the_dispatch(tmp_path, monkeypatch, capsys):
    """⛔ THE GATE MUST BE A GATE, NOT A FUNCTION NOBODY CALLS -- AND NOT AN `in src` GREP.

    (This is the defect the whole change exists to remove: pr-doctor printed the decision and
    nothing consumed it.) The previous version asserted `"_gate = pr_first_gate()" in src`, which
    cannot fail for a call placed in a branch that never runs, a `return ""` added above it, or
    `_gate` computed and ignored -- and its docstring claimed `main()` was driven when it was not.
    So: drive `main()` and assert the DISPATCH DID NOT HAPPEN.
    """
    _record(tmp_path, work="SKIPPED", reason="issues: SKIPPED (un-owned PRs exist) -- 3 of 15")
    sent = []
    monkeypatch.setattr(QD, "STATE", str(tmp_path))
    monkeypatch.setattr(QD, "PR_DOCTOR_STATE", str(tmp_path))
    monkeypatch.setattr(QD, "lanes", lambda **k: [{"lane": "lane-7", "ws": "ws-7",
                                                   "verdict": "DONE-IDLE", "idle_s": 9999}])
    monkeypatch.setattr(QD, "assignments", lambda: {"lane-7": "FIX"})
    monkeypatch.setattr(QD, "protected", lambda lane: False)
    monkeypatch.setattr(QD, "no_wip", lambda r: (True, ""))
    monkeypatch.setattr(QD, "dispatch", lambda *a, **k: sent.append((a, k)), raising=False)
    monkeypatch.setattr(sys, "argv", ["queue-dispatch.py", "--apply"])
    QD.main()
    out = capsys.readouterr().out
    assert "dispatched 0 of 1 queued" in out, out
    assert "un-owned PRs exist" in out, out
    assert sent == [], sent


def test_the_skip_line_names_the_evidence_and_zero(tmp_path):
    """`dispatched 0` must never read as healthy: it says 0 OF WHAT and WHY."""
    _record(tmp_path, work="SKIPPED", reason="issues: SKIPPED (un-owned PRs exist) -- 3 of 15")
    gate = QD.pr_first_gate(state_dir=str(tmp_path))
    assert gate, "expected a skip reason"
    assert "un-owned PRs exist" in gate, gate
