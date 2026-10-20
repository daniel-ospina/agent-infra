#!/usr/bin/env python3
"""test_queue_dispatch.py -- #1876: `sh()` must keep stdout and stderr APART.

WHY THIS FILE EXISTS (the measured defect, not a hypothesis). `sh()` in
`scripts/queue-dispatch.py` returned `(rc, stdout + stderr)`, and `lanes()` fed that
concatenation to `json.loads`. `lane-status.py` writes its `DEGRADED` notice to STDERR on
purpose (its `if LIVE_READABLE is False:` branch: "stderr, so stdout stays a parseable fleet
read for callers that inspect LIVE_READABLE" — named, not numbered), so the moment the cmux
roster read degraded, the notice landed
INSIDE the JSON byte stream: `json.loads` raised `Extra data: line 928 column 1 (char
276xx)` -- the fixed offset being the end of the JSON, where the stderr line began --
`LaneReadError` was raised, and the whole dispatch pass ABORTED without dispatching
anything. Measured on the box: 259 `ABORT — LANE ROSTER` lines against 284 completed
passes, i.e. ~48% of passes aborting. That is why the dispatcher stopped feeding the fleet.

WHAT IS PINNED HERE -- THREE KINDS, AND WHICH FILE EACH ONE IS PINNED AGAINST. A first revision
of this header claimed the first kind for EVERY case, which is the same "the artifact asserts
something it does not verify" defect this PR is about (found by the fresh-context reviewer of
this diff, then MEASURED here). Two different "pre-fix" files exist and they fail DIFFERENT
cases, so each group below names its own:

  A. PINS AGAINST THE PRE-FIX FILE -- `origin/main`'s `queue-dispatch.py`, the one that returns
     `(rc, stdout + stderr)`. MEASURED, by dropping that file in beside this one and running it:
     **10 failed, 22 passed**; the 10 are
    * `test_sh_returns_stdout_and_stderr_separately`, `test_sh_timeout_puts_the_reason_on_stderr_and_leaves_stdout_empty`
    * `test_a_python_warning_on_stderr_does_not_abort_a_healthy_roster`,
      `test_a_stray_stderr_line_cannot_enter_the_json_parse`,
      `test_the_degraded_notice_is_still_loud`
    * `test_a_degraded_roster_aborts_even_with_the_notice_on_stderr` (pre-fix it aborts on
      `Extra data`, not on the DEGRADED ROWS -- so it belongs here, not with the controls)
    * `test_a_stderr_only_line_is_never_a_queue_item`,
      `test_the_item_is_the_first_stdout_line_with_stderr_noise_present`
    * `test_a_send_verdict_on_stderr_is_ambiguous_not_a_failed_start` (on THAT file it fails
      only because `interpret_send()` does not exist there; its behavioural pin is group B)

  B. PINS AGAINST THIS BRANCH'S FIRST REVISION -- streams already split, but `_detail = err or
     out` chosen BEFORE stripping, `sh()`'s own `"(timeout)"` sentinel echoed as if
     lane-status.py had written it, and the `rc == 4` decision reading stdout alone. These
     PASS on the pre-fix file (its merged stream happens to carry the reason, and it has no
     echo line to misattribute), so they are invisible to a pre-fix run -- which is exactly why
     they are named separately. MEASURED by reverting all four sites at once (4 failed, 28 passed):
    * `test_a_failed_roster_read_falls_back_to_stdout_for_its_reason[   \\n]`
    * `test_a_failed_queue_read_falls_back_to_stdout_when_stderr_is_blank`
    * `test_a_timed_out_roster_does_not_blame_lane_status_for_our_own_sentinel`
    * `test_main_keeps_the_claim_when_the_send_verdict_arrives_only_on_stderr` (dropping `err` at
      `main()`'s call site alone reds exactly this one -- 1 failed, 31 passed)
    * (the send-verdict case above, when only the stderr merge is dropped INSIDE `interpret_send`)

  C. GATE-PRESERVATION CONTROLS -- they pass on BOTH files BY DESIGN, because the fix must not
     open the fail-closed gate: `test_an_unreadable_roster_still_aborts` (all 5 params),
     `test_a_failed_roster_read_falls_back_to_stdout_for_its_reason[]` (the empty-stderr
     control -- the pair with its `[   \\n]` sibling is what pins the STRIPPING, not the
     fallback's existence), `test_a_timed_out_roster_still_aborts`,
     `test_a_still_empty_queue_reads_as_empty_not_as_an_error`,
     `test_a_failed_queue_read_quotes_stderr`, `test_the_send_path_still_sees_stderr`.

A reader who trims "redundant" tests here would trim THE LOAD-BEARING ONES -- that is why the
split is written down, and why each group states the file it was measured against instead of
one blanket claim.

⛔ WHAT THIS FIX DOES **NOT** DELIVER, SAID HERE SO NO TITLE HAS TO CARRY IT (#1876 review, P1).
A genuinely DEGRADED roster still ABORTS the pass -- exit 3, `LaneReadError("... DEGRADED
roster ...")` -- exactly as it did before the split, and `test_a_degraded_roster_aborts_even_
with_the_notice_on_stderr` pins that. That is deliberate: those rows are the hand-written TSV
alone, every live-only lane is invisible in them, and `lane-actions.py`'s `_refuse_if_degraded`
refuses the same payload. The split buys a BETTER REFUSAL there (it names the blind rows
instead of reporting `Extra data: line 928 column 1`), not dispatch. The starvation that
refusal causes is a separate question -- whether a TSV-only roster may ever dispatch work --
and this suite does not answer it.

TWO SUBJECTS LIVE IN THIS FILE, both on `queue-dispatch.py` (the file is per-SUT, not per-topic):

  1. The stream-split pins and their gate-preservation controls (#1876), described above.
  2. THE OWNER'S DISPATCH PRIORITY (2026-10-18, `pr-doctor.py`'s `issue_work` verdict): "un-owned
     PRs first -- a PR is owned only if a LIVE process has it -- then new issues." Before that gate
     existed NOTHING consumed the verdict, so the rule lived in a log line and a reader could not
     tell "no new work was needed" from "new work was skipped". Its cases are in section 0, and they
     pin every direction in which the gate must NOT block: a measurement that is missing, stale,
     unreadable or produced by a REFUSED pass has not answered the question, and blocking all issue
     dispatch on it would let one broken component starve the rest of the fleet.

Run:  python3 -m pytest scripts/test_queue_dispatch.py -q
      python3 scripts/test_queue_dispatch.py         # same, via the pytest runner this file imports
"""
from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import sys
import time

import pytest

_SPEC = importlib.util.spec_from_file_location(
    "queue_dispatch_under_test", pathlib.Path(__file__).with_name("queue-dispatch.py"))
qd = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(qd)          # module-level code is constants only — side-effect free

HERE = os.path.dirname(os.path.abspath(__file__))


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


def test_a_python_warning_on_stderr_does_not_abort_a_healthy_roster(tmp_path, monkeypatch):
    """ACCEPTANCE #1 of #1876, stated for what this fix ACTUALLY delivers: stderr from a
    source that is NOT the degraded path cannot break a healthy roster read.

    PRE-fix this raises `LaneReadError: lane-status.py output unparseable: Extra data: line 2
    column 1` — the warning line glued to the end of the JSON, which is the abort that stopped
    the dispatcher feeding the fleet. Post-fix the roster parses and the pass dispatches.

    ⛔ WHY A PYTHON WARNING AND NOT A `DEGRADED` NOTICE (the fixture used to be the notice, and
    that fixture is a pair the producer CANNOT EMIT — see the boundary test below): this is the
    incident's OTHER candidate cause, and the one the split genuinely cures. `lane-status.py`
    can carry stray stderr from a `DeprecationWarning`, a `sitecustomize` note or a shim on a
    pass whose roster is perfectly healthy, and NOTHING measured those before this fix.
    """
    _lane_status(tmp_path, monkeypatch, stdout=_ONE_LANE,
                 stderr="lane-status.py:42: DeprecationWarning: distutils Version classes are "
                        "deprecated\n")
    rows = qd.lanes(scan_timeout=30)
    assert [r["lane"] for r in rows] == ["lane-a"]


def test_a_stray_stderr_line_cannot_enter_the_json_parse(tmp_path, monkeypatch):
    """THE STREAM BOUNDARY ITSELF, on the very line that caused the incident.

    ⛔ THIS FIXTURE IS DELIBERATELY NOT A PAYLOAD `lane-status.py` CAN PRODUCE, and the first
    revision of this file asserted the opposite of that. `scripts/lane-status.py` writes this
    notice under `if LIVE_READABLE is False:` and stamps every emitted row
    `degraded=(LIVE_READABLE is False)` — the SAME global, in the same commit — so a DEGRADED
    notice on stderr always travels WITH `degraded: true` rows. Pairing it with clean rows
    isolates the boundary (any stderr line, whatever its source, must stay out of the parse)
    and proves nothing about whether a degraded roster dispatches.

    The pair the producer really emits is asserted below in
    `test_a_degraded_roster_aborts_even_with_the_notice_on_stderr` — it still ABORTS, by design.
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

    It is pinned against THIS BRANCH'S FIRST REVISION (streams split, but `err or out` chosen
    before stripping): there it raises `LaneReadError: ... (no output)` and the match fails. On
    `origin/main`'s merged-stream file it PASSES -- the glued stdout happens to carry the reason
    -- so a "pre-fix" run cannot see this one. The empty-stderr case is the control that passed
    on both, kept so the pair pins the STRIPPING, not the fallback's existence.
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

    Pinned against this branch's first revision, like its `lanes()` sibling: there it raises
    `QueueReadError: ... (no output)`; on `origin/main`'s merged-stream file it passes.
    """
    _claim(tmp_path, monkeypatch,
           stdout="claim.py: a missing queue is UNKNOWN, not empty\n", stderr=" \n", rc=2)
    with pytest.raises(qd.QueueReadError, match="missing queue is UNKNOWN"):
        qd.claim_next("lane-a", "LANDABLE.tsv")


# ── 4. the one merged read the issue KEEPS, made at its own call site ──────────────────────

def test_the_send_path_still_sees_stderr(tmp_path, monkeypatch, capsys):
    """`safe-send.sh`'s subject is PROSE, not structure, so its stderr is still quotable at
    the send call sites. This pins the explicit merge against the cleanup a future reader is
    most likely to make -- a split-only `sh()` with no merge at this call site (no such file
    exists in this repo's history; it is the hypothetical): that would print
    `CONTINUE-FAILED lane-a rc=5` with an EMPTY reason, which is how a version-check failure
    hid behind a composer story before (2026-10-01).
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


def test_main_keeps_the_claim_when_the_send_verdict_arrives_only_on_stderr(
        tmp_path, monkeypatch, capsys):
    """⛔ `main()`'S SEND CALL SITE, NOT JUST THE DECISION FUNCTION (#1876 review, P2).

    `interpret_send()` was already pinned, but nothing drove `main()`: replacing the pass-through
    with `interpret_send(rc, out, "")` left every case green while restoring the harm — an rc=4
    `sent-but-not-consumed` verdict arriving on stderr would classify FAILED-TO-START, the claim
    would be RELEASED, and the next tick would stack a SECOND item into a composer that may
    already hold the first. So this test drives the real `main()` loop with a stubbed `sh()` and
    a stubbed `claim_next()` and asserts the claim is KEPT.

    Non-vacuity: with `err` dropped at that one call site the `free` assertion below and the
    AMBIGUOUS print both fail (measured: 1 failed on the mutation, green on the fix).
    """
    calls = []
    monkeypatch.setattr(qd, "TMPD", str(tmp_path / "briefs"))
    monkeypatch.setattr(qd, "COOLDOWN_DIR", str(tmp_path / "cooldown"))
    monkeypatch.setattr(qd, "STATE", str(tmp_path))
    monkeypatch.setattr(qd, "_single_instance", lambda: object())
    monkeypatch.setattr(qd, "assignments", lambda: {"lane-a": "4-REVIEW"})
    monkeypatch.setattr(qd, "lanes", lambda **kw: [
        {"lane": "lane-a", "ws": "ws-a", "verdict": "DONE-IDLE"}])
    monkeypatch.setattr(qd, "no_wip", lambda r: (True, ""))
    monkeypatch.setattr(qd, "pr_first_gate", lambda: "")
    monkeypatch.setattr(qd, "cool", lambda lane: True)
    monkeypatch.setattr(qd, "classify_last_turn", lambda r: ("finished_the_work", {}))
    qfile = tmp_path / "REMEDY.tsv"
    qfile.write_text("4-REVIEW\t4242\tPR 4242\tw\tb\tfix it\twhy\n", encoding="utf-8")
    monkeypatch.setattr(qd, "CLAIM", str(tmp_path / "claim-fixture.py"))
    monkeypatch.setattr(qd, "claim_next", lambda lane, q: ("PR 4242 — fix it", str(qfile)))
    monkeypatch.setattr(qd, "pr_still_open", lambda item: "OPEN")
    sent = []
    monkeypatch.setattr(qd, "mark_sent", lambda lane: sent.append(lane))

    def fake_sh(cmd, timeout=90):
        calls.append(list(cmd))
        if "safe-send.sh" in str(cmd[1]):
            # rc=4 with the verdict on STDERR ONLY: bytes written, no turn confirmed.
            return 4, "", "sent-but-not-consumed\n"
        return 0, "", ""                                    # the CLAIM free/done calls

    monkeypatch.setattr(qd, "sh", fake_sh)
    monkeypatch.setattr(sys, "argv", ["queue-dispatch.py", "--apply"])

    qd.main()
    out = capsys.readouterr().out
    assert "AMBIGUOUS" in out, out
    assert "FAILED-TO-START" not in out, out
    assert not any("free" in c for c in calls), \
        f"the claim was RELEASED over a possibly-sent item: {calls}"
    assert sent == [] , "a send that was never consumed must not start a cooldown"


# ── 0. the owner's dispatch priority gate (`pr_first_gate`) ─────────────────────────────────
# Merged with the stream-split suite above: both subjects are `queue-dispatch.py`, and the two
# sides landed one file each. Neither set replaces the other — a side picked here would delete
# live pins, which is the failure mode this section's provenance note exists to prevent.

def _record(tmp_path, *, rc=0, work="SKIPPED", age_s=60.0, reason="dispatched 3 of 9 queued — ok",
            **extra):
    d = {"rc": rc, "issue_work": work, "reason": reason,
         "at_epoch": time.time() - age_s}
    d.update(extra)
    (tmp_path / "pr-doctor.status.json").write_text(json.dumps(d))


def test_no_record_is_not_a_block(tmp_path, capsys):
    """A dispatcher that has never run must not stop issue work -- it has measured nothing."""
    assert qd.pr_first_gate(state_dir=str(tmp_path)) == ""
    assert "recorded no pass yet" in capsys.readouterr().out


def test_un_owned_PRs_skip_new_issue_work(tmp_path):
    """THE OWNER'S RULE: un-owned PRs exist -> new issue work is SKIPPED, and it says why."""
    _record(tmp_path, work="SKIPPED", reason="issues: SKIPPED (un-owned PRs exist) -- 3 of 15")
    gate = qd.pr_first_gate(state_dir=str(tmp_path))
    assert gate.startswith("issues: SKIPPED (un-owned PRs exist)"), gate
    assert "3 of 15" in gate, gate          # the EVIDENCE travels with the refusal


def test_every_PR_owned_lets_issue_work_proceed(tmp_path):
    _record(tmp_path, work="ELIGIBLE", reason="issues: ELIGIBLE (no un-owned PRs)")
    assert qd.pr_first_gate(state_dir=str(tmp_path)) == ""


def test_a_STALE_record_does_not_gate(tmp_path, capsys):
    """⛔ A RECORD IS A PAST STATE. Beyond two 1200s dispatch intervals it is not a measurement."""
    _record(tmp_path, age_s=qd.PR_FIRST_MAX_AGE_S + 60)
    assert qd.pr_first_gate(state_dir=str(tmp_path)) == ""
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
    assert qd.pr_first_gate(state_dir=str(tmp_path)) == ""
    assert "measured no ownership verdict" in capsys.readouterr().out


def test_a_REFUSED_but_measured_pass_STILL_gates(tmp_path, capsys):
    """rc=3 means the order was not placed -- the PRs were still measured, so the rule still holds."""
    _record(tmp_path, rc=3, work="SKIPPED",
            reason="no idle lane in the roster; 1 order(s) no lane accepted")
    gate = qd.pr_first_gate(state_dir=str(tmp_path))
    assert gate.startswith("issues: SKIPPED (un-owned PRs exist)"), gate
    assert "also refused, rc=3" in capsys.readouterr().out


def test_an_UNREADABLE_record_does_not_gate(tmp_path, capsys):
    """Absence of a readable verdict is not a verdict -- and it says so instead of guessing."""
    (tmp_path / "pr-doctor.status.json").write_text("{not json")
    assert qd.pr_first_gate(state_dir=str(tmp_path)) == ""
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
    gate = qd.pr_first_gate(state_dir=str(tmp_path))
    assert gate, "expected a skip reason"
    assert "un-owned PRs exist" in gate, gate


if __name__ == "__main__":
    import sys
    sys.exit(pytest.main([__file__, "-q"]))
