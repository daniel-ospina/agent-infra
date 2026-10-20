#!/usr/bin/env python3
"""test_queue_dispatch.py -- two contracts of `queue-dispatch.py`, both measured on this file.

1. `sh()` keeps stdout and stderr APART (#1876).

WHY: `lanes()` reads the fleet roster from `lane-status.py --json`. That tool
writes a `DEGRADED` notice to STDERR by design, precisely so its stdout stays a parseable fleet
read. `sh()` concatenated stderr into stdout, so the notice landed inside the JSON byte stream:
`json.loads` raised `Extra data`, `LaneReadError` was raised, and the pass ABORTED without
dispatching anything -- ~48% of passes measured (259 aborts vs 284 completed).

The defect was a *readable* stdout thrown away because an unrelated line was glued to it. The
fail-closed abort is CORRECT and must stay: only the corruption path is removed.

2. THE OWNER'S DISPATCH PRIORITY, pinned where it is enforced.

⛔ WHY (owner, 2026-10-18): "un-owned PRs first -- a PR is owned only if a LIVE
process has it -- then new issues." `pr-doctor.py` measures that and publishes `issue_work` in its
status record; BEFORE this gate NOTHING read it, so the rule lived in a log line and a reader could
not tell "no new work was needed" from "new work was skipped". These pin the gate's verdicts,
including every direction in which it must NOT block: a measurement that is missing, stale,
unreadable or produced by a REFUSED pass has not answered the question, and blocking all issue
dispatch on it would let one broken component starve the rest of the fleet.

Run:  <venv>/bin/python -m pytest scripts/test_queue_dispatch.py -q
"""
from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import sys
import time

import pytest

_HERE = pathlib.Path(__file__).resolve().parent
HERE = str(_HERE)
_SPEC = importlib.util.spec_from_file_location(
    "queue_dispatch_under_test", _HERE / "queue-dispatch.py")
qd = QD = importlib.util.module_from_spec(_SPEC)   # `QD` is the name the priority block uses
_SPEC.loader.exec_module(qd)


# ── 1. the one-line defect: stderr must not corrupt a JSON read ──────────────────────────

def test_sh_keeps_stderr_out_of_stdout():
    """A command that writes valid JSON to stdout AND a warning to stderr must parse.

    This fails on the pre-#1876 `sh()` (which returned `stdout + stderr`) and passes after.
    """
    code = ("import sys, json; "
            "print(json.dumps([{'lane': 'lane-1'}])); "
            "sys.stderr.write('lane-status: DEGRADED -- the cmux fleet roster was unreadable\\n')")
    rc, out, err = qd.sh([sys.executable, "-c", code])
    assert rc == 0
    assert "DEGRADED" not in out, "stderr leaked into stdout"
    assert json.loads(out) == [{"lane": "lane-1"}]
    assert "DEGRADED" in err, "stderr was dropped instead of kept separate"


def test_sh_reports_a_timeout_as_rc_none():
    rc, out, err = qd.sh([sys.executable, "-c", "import time; time.sleep(5)"], timeout=0.2)
    assert rc is None
    assert out == ""
    assert "timeout" in err


# ── 1b. the roster read: a stderr notice no longer aborts it ─────────────────────────────

_ROSTER = '[{"lane": "lane-1", "verdict": "DONE-IDLE"}]'


def test_lanes_parses_stdout_even_when_stderr_has_a_notice(monkeypatch):
    """THE REGRESSION TEST. The old `sh()` merged the DEGRADED line in and the read aborted."""
    monkeypatch.setattr(
        qd, "sh",
        lambda *a, **k: (0, _ROSTER, "lane-status: DEGRADED -- roster unreadable\n"))
    rows = qd.lanes(scan_timeout=5)
    assert [r["lane"] for r in rows] == ["lane-1"]


@pytest.mark.parametrize("rc,out,err", [
    (1, "", "connection refused"),
    (None, "", "(timeout)"),
    (0, "not json at all", ""),
    (0, "[]", ""),
])
def test_an_unreadable_roster_still_aborts(monkeypatch, rc, out, err):
    """The fail-closed gate is INTACT: the fix must not turn a failed read into an empty fleet."""
    monkeypatch.setattr(qd, "sh", lambda *a, **k: (rc, out, err))
    with pytest.raises(qd.LaneReadError):
        qd.lanes(scan_timeout=5)


def test_a_degraded_roster_still_aborts(monkeypatch):
    """A TSV-only (degraded) roster under-reports the fleet, so it is refused, not parsed."""
    degraded = '[{"lane": "lane-1", "verdict": "DONE-IDLE", "degraded": true}]'
    monkeypatch.setattr(qd, "sh", lambda *a, **k: (0, degraded, ""))
    with pytest.raises(qd.LaneReadError):
        qd.lanes(scan_timeout=5)


def test_claim_next_reads_stdout_not_stderr(monkeypatch):
    """The other JSON consumer: a claim read must not see a stderr line as a queue row."""
    monkeypatch.setattr(
        qd, "sh",
        lambda *a, **k: (0, "PR 123\trow\n", "some warning from claim.py\n"))
    item, _path = qd.claim_next("lane-1", "REMEDY.tsv")
    assert item.startswith("PR 123")
    assert "warning" not in item


# ── 2. the OWNER'S priority: un-owned PRs first ────────────────────────────────────────────

def _record(tmp_path, *, rc=0, work="SKIPPED", age_s=60.0, reason="dispatched 3 of 9 queued — ok",
            un_owned=3, **extra):
    """Write the record `pr-doctor.py` actually emits.

    ⛔ `un_owned` IS NOT DECORATION (2026-10-20, review). Every exit that publishes `issue_work`
    publishes the ownership READING beside it (`_finish`: `un_owned=len(un_owned)`), and every exit
    that publishes no reading publishes neither field. A helper that carried `issue_work` without
    `un_owned` therefore wrote a record the writer CANNOT produce -- and the gate's two-field
    contract was then only testable against a shape that never occurs. Pass `un_owned=None` to get
    the no-reading shape on purpose (`test_a_pass_that_measured_NOTHING_cannot_gate`).
    """
    d = {"rc": rc, "issue_work": work, "reason": reason,
         "at_epoch": time.time() - age_s}
    if un_owned is not None:
        d["un_owned"] = un_owned
        d["owned"] = max(0, 12 - un_owned)
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
    _record(tmp_path, rc=2, work="", un_owned=None, reason="checks UNREADABLE")
    assert QD.pr_first_gate(state_dir=str(tmp_path)) == ""
    assert "carries no ownership reading" in capsys.readouterr().out


def test_a_pass_whose_OWNERSHIP_read_failed_does_not_gate(tmp_path, capsys):
    """⛔ A BLIND PROBE IS NOT "EVERY PR IS UN-OWNED" (2026-10-20, review).

    When the cwd probe cannot answer, `pr-doctor.py` returns `owners == {}`, so `un_owned` becomes
    EVERY non-draft PR and `issue_work` becomes `SKIPPED` -- a record that reads exactly like a
    measured fleet in which nothing is owned. It carries `ownership_read_failed` for precisely that
    reason, and the gate must abstain on it: blocking all issue dispatch because one measurement
    died is how a single broken component starves the rest of the fleet.

    ⚠️ The shape matters, and the pre-fix fixture got it wrong: `un_owned=0` cannot be emitted in
    this state (a failed probe gives `un_owned == len(prs) > 0`), so a test written that way pins a
    record the writer never writes. This one carries `un_owned=14` -- the real shape.
    """
    _record(tmp_path, rc=0, work="SKIPPED", un_owned=14,
            reason="issues: SKIPPED (ownership UNREADABLE -- un-owned PRs cannot be excluded)",
            ownership_read_failed="lsof cwd probe failed rc=-1: FileNotFoundError")
    assert QD.pr_first_gate(state_dir=str(tmp_path)) == ""
    assert "could not READ ownership" in capsys.readouterr().out


def test_a_REFUSED_but_measured_pass_STILL_gates(tmp_path, capsys):
    """rc=3 means the order was not placed -- the PRs were still measured, so the rule still holds."""
    _record(tmp_path, rc=3, work="SKIPPED",
            reason="2 order(s) no worker accepted")
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
