#!/usr/bin/env python3
"""test_queue_dispatch.py -- #1876: `sh()` must keep stdout and stderr APART.

WHY THIS FILE EXISTS (the measured defect, not a hypothesis). `sh()` in
`scripts/queue-dispatch.py` returned `(rc, stdout + stderr)`, and `lanes()` fed that
concatenation to `json.loads`. `lane-status.py` writes its `DEGRADED` notice to STDERR on
purpose (`lane-status.py:545`: "so stdout stays a parseable fleet read for callers that
inspect LIVE_READABLE"), so the moment the cmux roster read degraded, the notice landed
INSIDE the JSON byte stream: `json.loads` raised `Extra data: line 928 column 1 (char
276xx)` -- the fixed offset being the end of the JSON, where the stderr line began --
`LaneReadError` was raised, and the whole dispatch pass ABORTED without dispatching
anything. Measured on the box: 259 `ABORT — LANE ROSTER` lines against 284 completed
passes, i.e. ~48% of passes aborting. That is why the dispatcher stopped feeding the fleet.

WHAT IS PINNED HERE. The cases are one of two kinds, and the header used to claim the
first kind for all of them -- which is the same "the artifact asserts something it does not
verify" defect this PR is about (found by the fresh-context reader of this very diff):

  REGRESSION PINS -- they FAIL on the pre-fix `(rc, stdout + stderr)` file:
    * `test_sh_returns_stdout_and_stderr_separately`, `test_sh_timeout_puts_the_reason_on_stderr_and_leaves_stdout_empty`
    * `test_a_degraded_notice_does_not_break_a_readable_roster`, `test_the_degraded_notice_is_still_loud`
    * `test_a_stderr_only_line_is_never_a_queue_item`,
      `test_the_item_is_the_first_stdout_line_with_stderr_noise_present`
    * `test_a_failed_roster_read_falls_back_to_stdout_for_its_reason[   \\n]` and
      `test_a_failed_queue_read_falls_back_to_stdout_when_stderr_is_blank`
    * `test_a_send_verdict_on_stderr_is_ambiguous_not_a_failed_start` (the helpers are new;
      pre-fix the rc=4 branch read `out` with no merge at all)

  GATE-PRESERVATION CONTROLS -- they pass on BOTH files BY DESIGN, because the fix must not
open the fail-closed gate: `test_an_unreadable_roster_still_aborts` (all 5 params),
`test_a_degraded_roster_aborts_even_with_the_notice_on_stderr`,
`test_a_timed_out_roster_still_aborts`,
`test_a_timed_out_roster_does_not_blame_lane_status_for_our_own_sentinel`,
`test_a_still_empty_queue_reads_as_empty_not_as_an_error`,
`test_a_failed_queue_read_quotes_stderr`,
`test_a_failed_roster_read_falls_back_to_stdout_for_its_reason[]` (the empty-stderr control),
`test_the_send_path_still_sees_stderr`. A reader who trims "redundant" tests here would trim
THE LOAD-BEARING ONES -- that is why the split is written down.

Run:  python3 -m pytest scripts/test_queue_dispatch.py -q
      python3 scripts/test_queue_dispatch.py         # same, via the pytest runner this file imports
"""
from __future__ import annotations

import importlib.util
import json
import pathlib

import pytest

_SPEC = importlib.util.spec_from_file_location(
    "queue_dispatch_under_test", pathlib.Path(__file__).with_name("queue-dispatch.py"))
qd = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(qd)          # module-level code is constants only — side-effect free


# ── fixtures: REAL subprocesses writing REAL streams, through the REAL sh() ─────────────────
# A canned `sh()` fake would test the fake. Every case below spawns a python fixture that
# writes to the stream under test, so the code path exercised is the shipped one.

def _script(tmp_path, name: str, body: str) -> str:
    p = tmp_path / name
    p.write_text(body, encoding="utf-8")
    return str(p)


def _lane_status(tmp_path, monkeypatch, *, stdout: str, stderr: str = "", rc: int = 0,
                 sleep: float = 0.0) -> None:
    """Point `lanes()` at a fixture that behaves like lane-status.py's OUTPUT CONTRACT."""
    body = (
        "import sys, time\n"
        + (f"time.sleep({sleep!r})\n" if sleep else "")
        + (f"sys.stdout.write({stdout!r})\n" if stdout else "")
        + (f"sys.stderr.write({stderr!r})\n" if stderr else "")
        + f"raise SystemExit({rc})\n"
    )
    monkeypatch.setattr(qd, "LANE_STATUS", _script(tmp_path, "lane-status-fixture.py", body))


def _claim(tmp_path, monkeypatch, *, stdout: str, stderr: str = "", rc: int = 0) -> None:
    body = (
        "import sys\n"
        + (f"sys.stdout.write({stdout!r})\n" if stdout else "")
        + (f"sys.stderr.write({stderr!r})\n" if stderr else "")
        + f"raise SystemExit({rc})\n"
    )
    monkeypatch.setattr(qd, "CLAIM", _script(tmp_path, "claim-fixture.py", body))
    monkeypatch.setattr(qd, "STATE", str(tmp_path))


_ONE_LANE = json.dumps([{"lane": "lane-a", "ws": "ws-a", "verdict": "DONE-IDLE"}])
_DEGRADED = ("lane-status: DEGRADED -- the cmux fleet roster was unreadable after 3 attempts; "
             "this scan covers the hand-written TSV only, so every live-only lane is INVISIBLE\n")


# ── 1. the regression itself: streams apart ────────────────────────────────────────────────

def test_sh_returns_stdout_and_stderr_separately():
    """The one-line defect: `(rc, stdout + stderr)`.

    On the pre-fix file this test cannot even reach its assertions -- the 2-tuple unpack
    raises `ValueError: not enough values to unpack` -- and the JSON is unparseable from the
    merged string for exactly the reason the issue measured (`Extra data`).
    """
    rc, out, err = qd.sh([
        "python3", "-c",
        "import sys; sys.stdout.write('{\"a\": 1}'); "
        "sys.stderr.write('lane-status: DEGRADED -- roster unreadable\\n')",
    ])
    assert rc == 0
    assert json.loads(out) == {"a": 1}          # ⛔ the assertion the pre-fix code fails
    assert "DEGRADED" in err
    assert "DEGRADED" not in out


def test_sh_timeout_puts_the_reason_on_stderr_and_leaves_stdout_empty():
    """A killed read has no output. If `(timeout)` arrived on stdout, a caller that parses
    only stdout could mistake the kill for content — the opposite of the fail-closed rule."""
    rc, out, err = qd.sh(["python3", "-c", "import time; time.sleep(5)"], timeout=0.3)
    assert rc is None
    assert out == ""
    assert err == "(timeout)"


def test_a_degraded_notice_does_not_break_a_readable_roster(tmp_path, monkeypatch):
    """ACCEPTANCE #1 of #1876: valid JSON on stdout AND a warning on stderr -> the parse succeeds.

    PRE-fix this raises `LaneReadError: lane-status.py output unparseable: Extra data: line 2
    column 1` — the DEGRADED line glued to the end of the JSON. That abort is what stopped
    the dispatcher feeding the fleet.
    """
    _lane_status(tmp_path, monkeypatch, stdout=_ONE_LANE, stderr=_DEGRADED)
    rows = qd.lanes(scan_timeout=30)
    assert [r["lane"] for r in rows] == ["lane-a"]


def test_the_degraded_notice_is_still_loud(tmp_path, monkeypatch, capsys):
    """Keeping stderr out of the PARSE must not silence it: lane-status put it there so it
    would be seen, so it is re-emitted on this process's stderr."""
    _lane_status(tmp_path, monkeypatch, stdout=_ONE_LANE, stderr=_DEGRADED)
    qd.lanes(scan_timeout=30)
    captured = capsys.readouterr()
    assert "DEGRADED" in captured.err
    assert "DEGRADED" not in captured.out       # stdout stays a clean summary


# ── 2. the fail-closed gate is NOT opened ──────────────────────────────────────────────────

@pytest.mark.parametrize("case", [
    # rc != 0 with the failure text where lane-status actually writes it: stderr
    {"stdout": "", "stderr": "lane-status: REFUSING — the roster is EMPTY\n", "rc": 3,
     "match": "roster is EMPTY"},
    # rc == 0 with NOTHING on stdout: a warning on stderr is not a fleet
    {"stdout": "", "stderr": _DEGRADED, "rc": 0, "match": "non-JSON"},
    # rc == 0 with non-JSON on stdout
    {"stdout": "not json at all\n", "stderr": "", "rc": 0, "match": "non-JSON"},
    # a readable, well-formed, but EMPTY roster is a refusal, not an empty fleet
    {"stdout": "[]", "stderr": "", "rc": 0, "match": "EMPTY roster"},
    # a DEGRADED (TSV-only) roster under-reports the fleet -> still refuses
    {"stdout": json.dumps([{"lane": "L", "ws": "w", "degraded": True}]),
     "stderr": "", "rc": 0, "match": "DEGRADED roster"},
])
def test_an_unreadable_roster_still_aborts(tmp_path, monkeypatch, capsys, case):
    """ACCEPTANCE #2 of #1876 — the fix must not open the fail-closed gate."""
    fixture = {k: v for k, v in case.items() if k != "match"}
    _lane_status(tmp_path, monkeypatch, **fixture)
    with pytest.raises(qd.LaneReadError, match=case["match"]):
        qd.lanes(scan_timeout=30)


def test_a_degraded_roster_aborts_even_with_the_notice_on_stderr(tmp_path, monkeypatch,
                                                                capsys):
    """Both signals at once: the notice on stderr AND the rows stamped `degraded`. Pre-fix
    the notice was glued to the JSON, so the abort fired on `Extra data` instead — still an
    abort, but one that says nothing about WHICH rows are blind. The verdict must come from
    the ROWS, which is the thing a supervisor can act on."""
    _lane_status(tmp_path, monkeypatch,
                 stdout=json.dumps([{"lane": "L", "ws": "w", "degraded": True}]),
                 stderr=_DEGRADED)
    with pytest.raises(qd.LaneReadError, match="DEGRADED roster"):
        qd.lanes(scan_timeout=30)
    assert "DEGRADED" in capsys.readouterr().err


@pytest.mark.parametrize("stderr", ["", "   \n"])
def test_a_failed_roster_read_falls_back_to_stdout_for_its_reason(tmp_path, monkeypatch,
                                                               stderr):
    """rc != 0 with the failure text on STDOUT and a BLANK (whitespace-only) stderr.

    The fallback must be on the STRIPPED text: `err or out` selects a whitespace-only stderr
    because `" \\n"` is truthy, strips it to `""`, and reports `(no output)` while stdout held
    the reason. That is the same defect class this whole fix removes — a failed read that
    cannot say WHY it failed — so the reason must survive either stream shape.

    PRE-fix this raises `LaneReadError: ... (no output)` and the match fails; the empty-stderr
    case is the control that already passed, kept so the pair pins the stripping, not the
    fallback's existence.
    """
    _lane_status(tmp_path, monkeypatch,
                 stdout="lane-status: REFUSING — the roster is EMPTY\n", stderr=stderr, rc=3)
    with pytest.raises(qd.LaneReadError, match="roster is EMPTY"):
        qd.lanes(scan_timeout=30)


def test_a_timed_out_roster_still_aborts(tmp_path, monkeypatch):
    """The 600s bound's whole purpose: a killed scan is UNKNOWN, never an empty fleet."""
    _lane_status(tmp_path, monkeypatch, stdout=_ONE_LANE, sleep=5)
    with pytest.raises(qd.LaneReadError, match="TIMED OUT"):
        qd.lanes(scan_timeout=0.3)


def test_a_timed_out_roster_does_not_blame_lane_status_for_our_own_sentinel(
        tmp_path, monkeypatch, capsys):
    """On a kill, `sh()` returns THIS FILE'S own `"(timeout)"` on the stderr channel -- not
    lane-status output. Re-emitting it unconditionally printed
    `queue-dispatch: lane-status stderr: (timeout)`, attributing our own timeout to the peer
    in the one log line an operator reads when a dispatch pass aborts.

    The abort still happens and still says TIMED OUT; only the misattributed echo is gone.
    """
    _lane_status(tmp_path, monkeypatch, stdout=_ONE_LANE, sleep=5)
    with pytest.raises(qd.LaneReadError, match="TIMED OUT"):
        qd.lanes(scan_timeout=0.3)
    assert "lane-status stderr" not in capsys.readouterr().err


# ── 3. the queue read: the same rule one function down ─────────────────────────────────────

def test_a_stderr_only_line_is_never_a_queue_item(tmp_path, monkeypatch, capsys):
    """⛔ THE FAIL-OPEN THE MERGE CREATED. `claim.py` writing a warning to stderr and nothing
    to stdout used to RETURN THAT WARNING AS THE ITEM — a live lane told to go work on
    "warning: ...". A stderr-only write is now an UNREAD queue: `QueueReadError`, one lane
    withheld, the rest of the pass proceeds.
    """
    _claim(tmp_path, monkeypatch, stdout="", stderr="warning: CLAIMS.tsv is locked; retrying\n")
    with pytest.raises(qd.QueueReadError, match="no output on STDOUT"):
        qd.claim_next("lane-a", "LANDABLE.tsv")


def test_the_item_is_the_first_stdout_line_with_stderr_noise_present(tmp_path, monkeypatch,
                                                                   capsys):
    _claim(tmp_path, monkeypatch, stdout="PR 1234 fix the thing\tland\n",
           stderr="claim: took a lock\n")
    item, path = qd.claim_next("lane-a", "LANDABLE.tsv")
    assert item == "PR 1234 fix the thing\tland"
    assert path.endswith("LANDABLE.tsv")
    assert "took a lock" in capsys.readouterr().err      # loud, not parsed


def test_a_still_empty_queue_reads_as_empty_not_as_an_error(tmp_path, monkeypatch):
    """The other polarity: a READ queue that genuinely answers NONE is not a failure."""
    _claim(tmp_path, monkeypatch, stdout="NONE\n")
    item, _ = qd.claim_next("lane-a", "LANDABLE.tsv")
    assert item is None


def test_a_failed_queue_read_quotes_stderr(tmp_path, monkeypatch):
    """The abort must carry the reason, which claim.py puts on stderr."""
    _claim(tmp_path, monkeypatch, stdout="", stderr="claim.py: a missing queue is UNKNOWN, not empty\n",
           rc=2)
    with pytest.raises(qd.QueueReadError, match="missing queue is UNKNOWN"):
        qd.claim_next("lane-a", "LANDABLE.tsv")


def test_a_failed_queue_read_falls_back_to_stdout_when_stderr_is_blank(tmp_path, monkeypatch):
    """The same stripped-text fallback as `lanes()`: a blank-but-non-empty stderr
    (`" \\n"` is truthy) must not turn a real stdout reason into `(no output)`.

    PRE-fix this raises `QueueReadError: ... (no output)` and the match fails.
    """
    _claim(tmp_path, monkeypatch,
           stdout="claim.py: a missing queue is UNKNOWN, not empty\n", stderr=" \n", rc=2)
    with pytest.raises(qd.QueueReadError, match="missing queue is UNKNOWN"):
        qd.claim_next("lane-a", "LANDABLE.tsv")


# ── 4. the one merged read the issue KEEPS, made at its own call site ──────────────────────

def test_the_send_path_still_sees_stderr(tmp_path, monkeypatch, capsys):
    """`safe-send.sh`'s subject is PROSE, not structure, so its stderr is still quotable at
    the send call sites. This pins the explicit merge: a split-only `sh()` with no merge
    here would print `CONTINUE-FAILED lane-a rc=5` with an EMPTY reason, which is how a
    version-check failure hid behind a composer story before (2026-10-01).
    """
    send = _script(tmp_path, "safe-send-fixture.sh", (
        "echo 'FATAL [lane-a]: no python3.12 found -- cannot run cmux_dispatch.py' >&2\n"
        "exit 5\n"
    ))
    monkeypatch.setattr(qd, "SAFE_SEND", send)
    monkeypatch.setattr(qd, "TMPD", str(tmp_path / "briefs"))
    monkeypatch.setattr(qd, "COOLDOWN_DIR", str(tmp_path / "cooldown"))
    rc = qd.send_continue("lane-a", "ws-a", dry=False)
    assert rc == 5
    assert "FATAL" in capsys.readouterr().out


def test_a_send_verdict_on_stderr_is_ambiguous_not_a_failed_start():
    """⛔ THE CLAIM-KEEPING DECISION AT `main()`'s SEND SITE, decided from EITHER stream.

    `rc == 4` means two very different things and the difference is a WORD:
      * `sent-but-not-consumed` -> AMBIGUOUS: bytes were written, no turn confirmed, the text
        may be sitting in the composer. The claim is KEPT so the next tick cannot send a
        SECOND item on top of it.
      * no such word -> FAILED-TO-START: a version-check exit that never sent anything, so the
        claim is RELEASED.

    If the send site read stdout alone (the pre-fix state, and the state a "cleanup" that
    drops the merge would restore), a verdict arriving on stderr would be classified
    FAILED-TO-START: the claim released and the next tick stacking a second instruction into
    the same composer. This test drives that decision with the verdict on STDERR ONLY.
    """
    assert qd.interpret_send(4, "", "sent-but-not-consumed\n")[0] == "AMBIGUOUS"
    assert qd.interpret_send(4, "", "python3.12 missing -- version check failed\n")[0] == \
        "FAILED-TO-START"
    # control: the same words on the stream the pre-fix code did read
    assert qd.interpret_send(4, "sent-but-not-consumed\n", "")[0] == "AMBIGUOUS"
    # byte order is stdout-then-stderr, matching the old `p.stdout + p.stderr`
    assert qd.send_text("a", "b") == "ab"
    assert qd.send_text("", "b") == "b"
    # and the other verdicts are unchanged by the extraction
    for rc, expected in ((0, "SENT"), (3, "BUSY"), (5, "FAILED"), (None, "FAILED")):
        assert qd.interpret_send(rc, "", "")[0] == expected, rc
        assert qd.interpret_send(rc, "", "")[0] in qd.SEND_KINDS


if __name__ == "__main__":
    import sys
    sys.exit(pytest.main([__file__, "-q"]))
