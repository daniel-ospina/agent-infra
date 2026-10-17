#!/usr/bin/env python3
"""test_queue_dispatch.py -- `sh()` keeps stdout and stderr APART (#1876).

WHY THIS FILE EXISTS. `lanes()` reads the fleet roster from `lane-status.py --json`. That tool
writes a `DEGRADED` notice to STDERR by design, precisely so its stdout stays a parseable fleet
read. `sh()` concatenated stderr into stdout, so the notice landed inside the JSON byte stream:
`json.loads` raised `Extra data`, `LaneReadError` was raised, and the pass ABORTED without
dispatching anything -- ~48% of passes measured (259 aborts vs 284 completed).

The defect was a *readable* stdout thrown away because an unrelated line was glued to it. The
fail-closed abort is CORRECT and must stay: only the corruption path is removed.

Run:  <venv>/bin/python -m pytest test_queue_dispatch.py -q
"""
from __future__ import annotations

import importlib.util
import json
import pathlib
import sys

import pytest

_HERE = pathlib.Path(__file__).resolve().parent
_SPEC = importlib.util.spec_from_file_location(
    "queue_dispatch_under_test", _HERE / "queue-dispatch.py")
qd = importlib.util.module_from_spec(_SPEC)
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


# ── 2. the roster read: a stderr notice no longer aborts it ───────────────────────────────

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
