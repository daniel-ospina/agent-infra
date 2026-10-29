#!/usr/bin/env python3
r"""Proof that a LATE merge-rate answer is not reported as an ABSENT one (#2227).

MEASURED 2026-10-20: `gh` is serialised PER BOX (#2005), so one `gh pr view` cost **63.0 s at 13
lanes** against 0.676 s at 3 and 0.091 s on the wire. The beat's drain line then printed

    QUEUE: open=14 merged_24h=? have=1 need=? VERDICT=UNKNOWN (merge-rate read failed)

for a read that had merely not been SERVED yet -- and the same sentence was printed for an instant
403. Two causes that demand opposite responses, one message.

The three properties pinned here:
  * a read that ANSWERS late is DATA, and says how long it took;
  * a read that FAILS says what was tried, how long it waited, and the age of the last good sample;
  * a cached rate is NEVER presented as current (#1869): it appears only as `last_good_rate=` WITH
    its age (deliberately NOT spelled `merged_24h=`, so a `merged_24h=(\d+)` parser cannot match
    it), and it never reaches `drain_days` or the verdict.

Run:  <venv>/bin/python -m pytest scripts/test_merge_queue.py -q
"""
from __future__ import annotations

import importlib.util
import json
import os
import pathlib

import pytest

_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "merge-queue.py")


@pytest.fixture(scope="module")
def M():
    spec = importlib.util.spec_from_file_location("merge_queue_under_test", _PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def state(M, tmp_path, monkeypatch):
    """A scratch STATE with a real progress file, so `main()` never reads the live box."""
    prog = tmp_path / "beta-progress.json"
    prog.write_text(json.dumps({"open_prs": 14}))
    monkeypatch.setattr(M, "PROGRESS", str(prog))
    monkeypatch.setattr(M, "CACHE", str(tmp_path / "merge-queue.json"))
    monkeypatch.setattr(M, "STATE", str(tmp_path))
    monkeypatch.setattr(M, "count_merge_lanes", lambda: (1, ["PR 2"]))
    return tmp_path


def _clock(M, monkeypatch, ticks):
    it = iter(ticks)
    monkeypatch.setattr(M.time, "monotonic", lambda: next(it))


def test_a_failed_read_says_what_it_tried_how_long_it_waited_and_the_age_of_the_last_good(
        M, state, monkeypatch, capsys):
    """(b) `merged_24h=?` alone is three facts short of a diagnosis."""
    # Older than the 3600 s TTL, so the cache MISSES and the read is actually attempted.
    old = M.time.time() - 7200
    (state / "merge-queue.json").write_text(json.dumps({"ts": int(old), "merged_24h": 23}))
    monkeypatch.setattr(M, "gh", lambda *a: None)
    M.LAST_RATE_READ.clear()
    _clock(M, monkeypatch, [0.0, 100.4])
    M.main()
    out = capsys.readouterr().out
    assert "merged_24h=?" in out, out
    assert "waited=100.4s" in out, out                       # HOW LONG it waited
    assert "tried gh pr list --state merged" in out, out     # WHAT it tried
    assert "last_good=" in out, out                          # HOW OLD the last good sample is
    assert "VERDICT=UNKNOWN" in out, out


def test_a_cached_rate_is_shown_ONLY_as_stale_with_its_age_and_never_decides_the_verdict(
        M, state, monkeypatch, capsys):
    """(c) #1869 SURVIVES. 23 is the last good rate; it may be SHOWN, never ADOPTED.

    If it reached `drain_days` or the verdict, a stale number would be standing exactly where an
    unread one belongs -- and `VERDICT=OK` off a six-hour-old rate is a clearance nobody measured.
    """
    old = M.time.time() - 21600
    (state / "merge-queue.json").write_text(json.dumps({"ts": int(old), "merged_24h": 23}))
    monkeypatch.setattr(M, "gh", lambda *a: None)
    M.LAST_RATE_READ.clear()
    _clock(M, monkeypatch, [0.0, 63.4])
    M.main()
    out = capsys.readouterr().out
    assert "last_good_rate=23(aged " in out, out
    assert "NOT current" in out, out
    assert "drain_days=" not in out, out            # no ratio derived from a stale rate
    assert "VERDICT=UNKNOWN" in out, out            # ...and no verdict either
    assert "VERDICT=OK" not in out and "VERDICT=STALLED" not in out, out
    # the failure token carries NO current-looking count
    assert "merged_24h=23" not in out, out


def test_a_read_that_ANSWERS_late_is_DATA_with_its_latency(M, state, monkeypatch, capsys):
    """(a) A 63 s read is a MEASUREMENT, not a failure -- it must not be dressed as one.

    The rate is real, so the verdict is computed from it; the ONLY trace of the delay is the
    `read=SLOW` token, which says the answer is data and says how long it took.
    """
    rows = [{"mergedAt": M.time.strftime("%Y-%m-%dT%H:%M:%SZ", M.time.gmtime())}]
    monkeypatch.setattr(M, "gh", lambda *a: rows)
    M.LAST_RATE_READ.clear()
    _clock(M, monkeypatch, [0.0, 63.1])
    M.main()
    out = capsys.readouterr().out
    assert "merged_24h=1" in out, out
    assert "read=SLOW(waited=63.1s)" in out, out
    assert "the merge rate is DATA" in out, out
    assert "UNKNOWN" not in out, out


def test_a_fast_read_prints_no_SLOW_token(M, state, monkeypatch, capsys):
    """The negative control for (a): 0.7 s is the MEASURED quiet-box cost and says nothing."""
    rows = [{"mergedAt": M.time.strftime("%Y-%m-%dT%H:%M:%SZ", M.time.gmtime())}]
    monkeypatch.setattr(M, "gh", lambda *a: rows)
    M.LAST_RATE_READ.clear()
    _clock(M, monkeypatch, [0.0, 0.676])
    M.main()
    out = capsys.readouterr().out
    assert "merged_24h=1" in out, out
    assert "SLOW" not in out, out
