#!/usr/bin/env python3
"""Tests for the cmux payload-integrity helper (#1187).

The defect these pin is a FALSE PASS, so the tests are written around the four
verdicts the helper must keep distinct — and the one delivery verdict among them:

  * `VERIFIED`      — the payload's tail was APPENDED TO THE LANE'S TRANSCRIPT
                       after the pre-send baseline, i.e. it was SUBMITTED;
  * `PANE_ONLY`     — the tail is visible on the surface but nothing proves
                       submission (the composer renders what it holds);
  * `UNVERIFIED`    — "I could not see the tail", which covers a truncated
                       prefix, an unreadable surface, and an empty payload;
  * `SUBMIT_FAILED` — the terminating Enter itself raised, so submission was
                       never attempted.

Collapsing any of these into `VERIFIED` is the measured regression: `cmux send`
returned `OK` while the recipient received the first sentence of a 1,962-byte
message (issue #1187).
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import stat
import subprocess
import textwrap
import time

import pytest

_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "cmux_payload.py")
_ORCH_SEND = os.path.join(os.path.dirname(os.path.abspath(__file__)), "orch-send.sh")

_BRIEF_GATE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "orchestrator-harness", "brief-gate.sh")


def _research_first_block():
    """The canonical lane research contract, asked of the GATE, not pasted here.

    main's #2258 brief-gate (`scripts/orchestrator-harness/brief-gate.sh`) refuses any
    order that does not carry a scoped `## RESEARCH FIRST` block, and `orch-send.sh` runs
    it on EVERY dispatch before target resolution. A payload without the block is
    therefore not a dispatch at all — it is refused with rc=80 — so these fixtures must
    carry one, or the suite exercises a path production never takes.

    Asked of the gate rather than hard-coded so the two cannot drift: `--section lane`
    emits the block that brief-gate's own validator admits (its test pins that property,
    "the gate cannot refuse its own advice"). Same construction as main's
    `capacity-transfer.test.sh`, which builds its conforming brief with
    `brief-gate.sh --section lane`. ⛔ Not a bypass: the block is REAL contract text and
    the gate still runs and still validates it on every send below.
    """
    return subprocess.run(["bash", _BRIEF_GATE, "--section", "lane"],
                          capture_output=True, text=True, check=True).stdout


_RESEARCH = _research_first_block()

LONG = _RESEARCH + (
    "Read the brief at /tmp/1187-brief.md and execute it end to end. "
    "Do not stop to ask for permission, and do not merge. "
    "TAIL-SENTINEL-9f3c: the last instruction is the one that must arrive."
)

# ⛔ A TAIL CONTAINING A DOUBLE QUOTE (#1881 review P1/P2). This is not an exotic shape: the script's
# own header tells operators to send quoted text through `@file`. The session transcript is JSONL, so
# inside it a `"` is written `\"` — a marker built from the SENT text can never be a raw substring of
# those bytes, which made VERIFIED structurally unreachable for this payload, so the operator was told
# "SENT BUT NOT SUBMITTED" and invited to dispatch a duplicate of a message that had arrived.
QUOTED = _RESEARCH + (
    "Read the brief at /tmp/1187-brief.md and execute it end to end. "
    "Do not stop to ask for permission, and do not merge. "
    'When the last item is finished, say "done".'
)

# Same class, the other mandatory JSON escape: a backslash is written `\\` in a JSONL record.
BACKSLASHED = _RESEARCH + (
    "Read the brief at /tmp/1187-brief.md and execute it end to end. "
    "Do not stop to ask for permission, and do not merge. "
    "Write the report to C:\\tmp\\reports\\final.txt and stop."
)


@pytest.fixture(scope="module")
def P():
    spec = importlib.util.spec_from_file_location("cmux_payload_under_test", _PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _Proc:
    def __init__(self, stdout="", returncode=0):
        self.stdout = stdout
        self.returncode = returncode


def _fake_cmux(screen, surface_out=""):
    """A `run` seam standing in for the cmux CLI."""
    calls = {"send": 0, "read": 0}

    def run(argv, timeout=None):
        if argv[:2] == ["cmux", "send"]:
            calls["send"] += 1
            return _Proc("OK")
        if argv[:2] == ["cmux", "read-screen"]:
            calls["read"] += 1
            return _Proc(screen)
        if argv[:3] == ["cmux", "surface", "resume"]:
            return _Proc(surface_out)
        return _Proc("")

    run.calls = calls
    return run


def _noop_sleep(*_a, **_k):
    return None


# ── normalisation ─────────────────────────────────────────────────────────────

def test_flatten_collapses_newlines_to_one_line(P):
    assert P.flatten("a\nb   c\t\nd") == "a b c d"


def test_tail_marker_is_the_last_n_whitespace_stripped_chars(P):
    assert P.tail_marker("HELLO WORLD", 5) == "WORLD"


def test_tail_marker_strips_whitespace_so_a_wrap_cannot_defeat_it(P):
    # compact("abc def") == "abcdef"; the last 4 chars are "cdef".
    assert P.tail_marker("abc def", 4) == "cdef"


def test_tail_marker_empty_payload_is_empty(P):
    assert P.tail_marker("") == ""
    assert P.tail_marker("   \n\t ") == ""


# ── the core false-PASS boundary ──────────────────────────────────────────────

def test_full_payload_on_screen_is_a_pane_match(P):
    assert P.screen_has_payload(f"some earlier output\n{LONG}\n", LONG) is True


def test_prefix_truncation_is_unverified(P):
    # Exactly the measured failure: the head arrived, the tail did not.
    prefix = LONG[: len(LONG) // 3]
    assert P.screen_has_payload(prefix, LONG) is False


def test_tail_split_by_a_line_wrap_is_still_a_pane_match(P):
    # A column wrap inserts a break with no visible character; it must not
    # manufacture a false UNVERIFIED.
    wrapped = "Read the brief at /tmp/1187-brief.md and execute it end to end. "
    wrapped += "Do not stop to ask for permission, and do not merge. TAIL-SENTINEL-\n9f3c: "
    wrapped += "the last instruction is the one that must arrive."
    assert P.screen_has_payload(wrapped, LONG) is True


def test_empty_payload_is_never_verified(P):
    assert P.screen_has_payload("anything", "") is False


def test_unreadable_screen_is_never_verified(P):
    assert P.screen_has_payload("", LONG) is False
    assert P.screen_has_payload(None, LONG) is False


# ── transcript second source ──────────────────────────────────────────────────

def test_transcript_has_payload_reads_the_tail(P, tmp_path):
    f = tmp_path / "session.jsonl"
    f.write_text('{"type":"user"}\n' + LONG + "\n")
    assert P.transcript_has_payload(str(f), LONG) is True


def test_transcript_prefix_only_is_not_a_match(P, tmp_path):
    f = tmp_path / "session.jsonl"
    f.write_text('{"type":"user"}\n' + LONG[:40] + "\n")
    assert P.transcript_has_payload(str(f), LONG) is False


def test_transcript_unreadable_is_not_a_match(P, tmp_path):
    assert P.transcript_has_payload(str(tmp_path / "missing.jsonl"), LONG) is False


@pytest.mark.parametrize("payload,escaped", [(QUOTED, '\\"'), (BACKSLASHED, "\\\\")])
def test_transcript_matches_a_jsonl_record_whose_tail_needs_json_escaping(P, tmp_path, payload,
                                                                           escaped):
    """⛔ THE TRANSCRIPT IS JSONL (#1881 review P1/P2). `lane-read.py` does `json.loads(line)` and pulls
    the text out of the decoded object, so inside the record a `"` is written `\\"` and a `\\` as
    `\\\\`. Comparing the marker against the RAW bytes — which is all the pre-fix code did — can never
    match for such a payload, so VERIFIED is unreachable and the operator is told "SENT BUT NOT\n    SUBMITTED" with a remedy that invites a duplicate dispatch."""
    f = tmp_path / "session.jsonl"
    f.write_text(json.dumps({"type": "user", "content": payload}) + "\n", encoding="utf-8")
    marker = P.tail_marker(payload)
    # NON-VACUITY: the payload really does need escaping, so the pre-fix raw-byte comparison is
    # impossible — this assertion is the pre-fix condition, expressed against the same fixture.
    assert escaped in f.read_text(encoding="utf-8")
    assert marker not in P.compact(f.read_text(encoding="utf-8"))
    # ...and the decoded comparison finds it.
    assert P.transcript_has_payload(str(f), payload) is True


def test_a_jsonl_record_that_is_a_prefix_still_does_not_match(P, tmp_path):
    """Decoding must not become a match-anything: a TRUNCATED record is still not a delivery."""
    f = tmp_path / "session.jsonl"
    f.write_text(json.dumps({"type": "user", "content": QUOTED[:60]}) + "\n", encoding="utf-8")
    assert P.transcript_has_payload(str(f), QUOTED) is False


# ── send_verified verdicts ────────────────────────────────────────────────────

def test_pane_only_when_the_tail_is_visible_but_submission_is_unproven(P):
    """⛔ THE P0, PINNED (#1881 review). The pane renders the COMPOSER's content, submitted or not, so
    finding the payload there proves the text reached the input box and NOTHING more. This used to
    return VERIFIED — so a payload typed and never submitted (a dropped Enter, swallowed by
    `except: pass`) was reported CONSUMED, exit 0, and the lane never received the order."""
    run = _fake_cmux(f"working...\n{LONG}\n")
    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.PANE_ONLY
    assert verdict != P.VERIFIED
    # the payload was actually sent, then the terminating Enter
    assert run.calls["send"] == 2


def test_a_dropped_enter_is_never_verified(P):
    """The Enter is its own `cmux send`. If it fails, the payload sits in the composer — which is
    exactly what the pane shows for a delivered message too. The old code swallowed the failure and
    then read the composer as proof."""
    def run(argv, timeout=None):
        if argv[:2] == ["cmux", "send"]:
            calls = getattr(run, "n", 0) + 1
            run.n = calls
            if calls >= 2:                      # the terminating Enter
                raise RuntimeError("cmux send failed")
            return _Proc("OK")
        if argv[:2] == ["cmux", "read-screen"]:
            return _Proc(f"working...\n{LONG}\n")
        return _Proc("")

    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict != P.VERIFIED, "a dropped Enter must never be reported as delivered"


def test_verified_requires_the_transcript_to_record_this_send(P, tmp_path, monkeypatch):
    """VERIFIED needs SUBMISSION evidence: the tail appended to the lane's transcript AFTER the
    pre-send baseline. The pane is not evidence of the act."""
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    home = tmp_path / "home"
    sessions = home / ".pi" / "agent" / "sessions" / "proj"
    sessions.mkdir(parents=True)
    sess = sessions / f"2026-09-29T12-00-00Z-{sid}.jsonl"
    sess.write_text('{"type":"user","text":"an earlier message"}\n')
    monkeypatch.setenv("HOME", str(home))

    def run(argv, timeout=None):
        if argv[:2] == ["cmux", "send"]:
            payload = argv[-1]
            if payload != "\n":           # a real submit, not the terminating Enter
                fh = open(sess, "a", encoding="utf-8")
                fh.write(LONG + "\n")
                fh.close()
            return _Proc("OK")
        if argv[:2] == ["cmux", "read-screen"]:
            return _Proc("pane scrolled past the message")
        if argv[:3] == ["cmux", "surface", "resume"]:
            return _Proc(f"{sid}\n")
        return _Proc("")

    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.VERIFIED


def test_a_missing_baseline_never_reaches_verified(P, tmp_path, monkeypatch):
    """⛔ NO BASELINE, NO DELIVERY VERDICT (#1881 review P1). `transcript_offset` returns None when the
    transcript cannot be stat'ed, and `transcript_has_payload` treats a None `since_offset` as "search
    the last 2 MB". On a live lane that window spans DAYS, so an EARLIER identical message (a standing
    order, a nudge, the retry the recovery text prescribes) certified a LATER, truncated send — the
    occurrence-identity defect this PR exists to close, still live on the one path where the baseline
    was unavailable. The weaker read is refused at the ONE call site where it would be a false PASS.

    Fails on the pre-fix code: `session_base is None` still passed `since_offset=None` through."""
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    home = tmp_path / "home"
    sessions = home / ".pi" / "agent" / "sessions" / "proj"
    sessions.mkdir(parents=True)
    sess = sessions / f"2026-09-29T12-00-00Z-{sid}.jsonl"
    # The SAME payload, from long before this send. Without a baseline it is indistinguishable from
    # a message that just arrived — so it must not be usable as delivery evidence at all.
    sess.write_text('{"type":"user","text":"' + LONG + '"}\n', encoding="utf-8")
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setattr(P, "transcript_offset", lambda path: None)

    run = _fake_cmux(f"working...\n{LONG}\n", surface_out=f"{sid}\n")
    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict != P.VERIFIED, "a pre-existing occurrence certified a send with no baseline"
    assert verdict == P.PANE_ONLY


def test_a_workspace_only_fallback_can_never_mint_a_verified(P, tmp_path, monkeypatch):
    """⛔ AN UNQUALIFIED BINDING MAY NOT AWARD A VERDICT (#3795 review P2).

    When this box's `cmux` rejects `--surface`, the surface-qualified read FAILS and
    `resolve_session_id` retries WORKSPACE-ONLY. That answer names the WORKSPACE's session, not this
    surface's — the right pane only when the workspace holds one surface. On a multi-surface workspace
    it can name a DIFFERENT pane's session, and `send_verified` would then take its baseline from, and
    search for the payload tail inside, a transcript this send never wrote to.

    The reachable shape is the one pinned here: no transcript exists for the named session when the
    baseline is taken, so `may_await_new_file` is True and the tail search reopens at offset 0 over the
    last 2 MB. The floor's tail marker is byte-identical on every tick, so the OTHER pane writing the
    same heartbeat makes a copy satisfy the search — and the verdict becomes `VERIFIED` from bytes this
    send never produced. That is exactly the outcome this module refuses for an empty read ("how a
    VERIFIED gets minted from another pane's bytes"); a FAILED read is no better evidence of WHICH
    session it is.

    Fails on the pre-fix code: the fallback's id was used unconditionally, so the offset-0 window
    matched the other pane's copy and the verdict was `VERIFIED`.
    """
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    home = tmp_path / "home"
    sessions = home / ".pi" / "agent" / "sessions" / "proj"
    sessions.mkdir(parents=True)
    sess = sessions / f"2026-09-29T12-00-00Z-{sid}.jsonl"
    # NO transcript for `sid` yet: that is what licenses the offset-0 window after the send.
    monkeypatch.setenv("HOME", str(home))

    def run(argv, timeout=None):
        if argv[:3] == ["cmux", "surface", "resume"]:
            if "--surface" in argv:
                return _Proc("", returncode=2)      # this cmux does not know the flag
            return _Proc(f"{sid}\n")                 # ...so it names ANOTHER surface's session
        if argv[:2] == ["cmux", "send"]:
            if argv[-1] != "\n":                     # a real submit, not the terminating Enter
                # This send went to surf-9. The pane the fallback NAMED writes its own copy
                # independently — the same cadence text, on another surface.
                sess.write_text('{"type":"user","text":"' + LONG + '"}\n', encoding="utf-8")
            return _Proc("OK")
        if argv[:2] == ["cmux", "read-screen"]:
            return _Proc("pane scrolled past the message")
        return _Proc("")

    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep,
                                 timeout_s=0, surface="surf-9")
    assert verdict != P.VERIFIED, (
        "a workspace-only fallback answer certified a send to a surface it does not name — the "
        "verified bytes came from another pane's transcript")
    # It must also not be silently promoted past the value the module documents for an unknown id:
    # `UNVERIFIED`/`PANE_ONLY` are the honest shapes, and both keep the operator's remedy intact.
    assert verdict in (P.PANE_ONLY, P.UNVERIFIED), verdict


def test_a_nonzero_enter_exit_is_a_dropped_enter(P):
    """⛔ A NON-ZERO EXIT IS NOT A SUCCESS (#1881 review P2). `_default_run` does not raise on a
    non-zero status, and `entered` was only cleared in the EXCEPT arm — so a `cmux` whose Enter
    returned 2 left the flag True and the verdict PANE_ONLY, whose remedy invites the duplicate
    re-send the flag exists to forbid. The raised and the exit-status shapes are the same failure."""
    def run(argv, timeout=None):
        if argv[:2] == ["cmux", "send"]:
            run.n = getattr(run, "n", 0) + 1
            if run.n >= 2:                       # the terminating Enter
                return _Proc("", returncode=2)
            return _Proc("OK")
        if argv[:2] == ["cmux", "read-screen"]:
            return _Proc(f"working...\n{LONG}\n")
        return _Proc("")

    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.SUBMIT_FAILED
    assert verdict != P.PANE_ONLY


def test_a_nonzero_payload_send_exit_is_unverified(P):
    """The module header says a non-zero `cmux` exit folds into UNVERIFIED. Before this pin that
    branch did not exist: the payload send's status was never read, so a failed send went on to be
    judged by the pane and could return PANE_ONLY for a message that was never typed."""
    def run(argv, timeout=None):
        if argv[:2] == ["cmux", "send"]:
            return _Proc("", returncode=1)
        if argv[:2] == ["cmux", "read-screen"]:
            return _Proc(f"working...\n{LONG}\n")
        return _Proc("")

    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.UNVERIFIED


def test_an_unknown_session_id_never_licenses_the_two_mb_window(P, tmp_path, monkeypatch):
    """⛔ THE P1 THIS FIX ITSELF OPENED (#1881 review, round 3). `resolve_session_file` returned None
    for THREE different things — cmux errored, the pane printed no id yet, and the id is known but no
    file exists — and the re-resolution treated all three as "the file did not exist before the
    send", reopening the search at offset 0. For the first two that window is the last 2 MB of a
    transcript that may hold DAYS, so a pre-existing message with a matching body certified a send
    whose tail was never submitted — measured VERIFIED on the fix's own bytes, UNVERIFIED on its
    parent. Only a KNOWN id with NO file may reopen at 0.

    Fails on the round-2 bytes: the transient pre-send failure still reached VERIFIED."""
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    home = tmp_path / "home"
    sessions = home / ".pi" / "agent" / "sessions" / "proj"
    sessions.mkdir(parents=True)
    sess = sessions / f"2026-09-29T12-00-00Z-{sid}.jsonl"
    # Days-old identical message: the only occurrence in this transcript is NOT this send's.
    sess.write_text('{"type":"user","text":"' + LONG + '"}\n', encoding="utf-8")
    monkeypatch.setenv("HOME", str(home))

    resume_calls = {"n": 0}

    def run(argv, timeout=None):
        if argv[:3] == ["cmux", "surface", "resume"]:
            # The PRE-SEND read fails (transient); every later read works. Nothing established that
            # a transcript did not exist, so offset 0 is unsound.
            resume_calls["n"] += 1
            if resume_calls["n"] == 1:
                raise RuntimeError("cmux surface resume show: transient failure")
            return _Proc(f"{sid}\n")
        if argv[:2] == ["cmux", "send"]:
            return _Proc("OK")                    # sent, but nothing was appended
        if argv[:2] == ["cmux", "read-screen"]:
            return _Proc("working...\n")          # the tail is not even on the pane
        return _Proc("")

    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict != P.VERIFIED, "an unknown pre-send baseline certified a pre-existing message"


def test_a_failed_baseline_stat_on_an_existing_file_never_reaches_verified(P, tmp_path, monkeypatch):
    """The mirror ambiguity: the FILE resolved but its size could not be read, so the pre-send
    baseline is unknown while the file is known to hold history. Treating that as offset 0 would
    search that history, so VERIFIED stays unreachable for this send (the fail-closed direction:
    a false PANE_ONLY costs a re-read, a false VERIFIED dispatches a fragment)."""
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    home = tmp_path / "home"
    sessions = home / ".pi" / "agent" / "sessions" / "proj"
    sessions.mkdir(parents=True)
    sess = sessions / f"2026-09-29T12-00-00Z-{sid}.jsonl"
    sess.write_text('{"type":"user","text":"' + LONG + '"}\n', encoding="utf-8")
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setattr(P, "transcript_offset", lambda path: None)

    run = _fake_cmux(f"working...\n{LONG}\n", surface_out=f"{sid}\n")
    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.PANE_ONLY


def test_a_short_payload_is_not_certified_by_a_fragment_of_a_longer_word(P, tmp_path):
    """⛔ A SHORT MARKER IS NOT A SUBSTRING (#1881 review, round 4 P1). `tail_marker` returns the
    WHOLE compacted payload when it is shorter than `tail_chars`, and the comparison used to be a bare
    `marker in compact(...)`: a payload of `ok` was certified by the lane writing "checking the token
    now" ("token" contains "ok"), and a truncated `Retry` by `Retrying…`. The module's own defect
    class includes an 8-byte payload that vanished, so short payloads are in scope — for them the
    pre-fix check degenerated to "does this common word appear anywhere in the lane's next output".

    Fails on the round-3 bytes: they return True here."""
    f = tmp_path / "session.jsonl"
    f.write_text(json.dumps({"type": "assistant", "content": "checking the token now"}) + "\n",
                 encoding="utf-8")
    assert P.transcript_has_payload(str(f), "ok") is False
    assert P.screen_has_payload("assistant: checking the token now", "ok") is False


def test_a_short_payload_appended_as_its_own_record_still_verifies(P, tmp_path):
    """NON-VACUITY for the boundary rule: tightening it must not make a genuine short message
    unverifiable, or the operator gets a false 'not submitted' for an order that arrived."""
    f = tmp_path / "session.jsonl"
    f.write_text(json.dumps({"type": "user", "content": "ok"}) + "\n", encoding="utf-8")
    assert P.transcript_has_payload(str(f), "ok") is True
    # ...and the same payload as a bare text line (a non-JSON transcript).
    g = tmp_path / "plain.jsonl"
    g.write_text("ok\n", encoding="utf-8")
    assert P.transcript_has_payload(str(g), "ok") is True


def test_an_unnameable_existing_transcript_never_licenses_the_two_mb_window(P, tmp_path, monkeypatch):
    """⛔ THE ROUND-4 P1: AN UNNAMEABLE FILE IS NOT AN ABSENT FILE. `session_file_for` answers None for
    both "the glob found no file" and "the glob found files but the stat raised", and the loop used
    that None as proof the transcript did not exist before the send. So ONE transient `getmtime`
    error on a pre-existing 18 MB transcript reopened the search at offset 0, and a days-old identical
    message certified a send that appended nothing. Existence is answered by the GLOB alone.

    Fails on the round-3 bytes: they reach VERIFIED here."""
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    home = tmp_path / "home"
    sessions = home / ".pi" / "agent" / "sessions" / "proj"
    sessions.mkdir(parents=True)
    sess = sessions / f"2026-09-29T12-00-00Z-{sid}.jsonl"
    sess.write_text('{"type":"user","text":"' + LONG + '"}\n', encoding="utf-8")
    monkeypatch.setenv("HOME", str(home))

    real_getmtime = os.path.getmtime
    calls = {"n": 0}

    def flaky_getmtime(path):
        # The PRE-SEND read fails once; every later read succeeds. The file was there all along.
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError("transient stat failure")
        return real_getmtime(path)

    monkeypatch.setattr(P.os.path, "getmtime", flaky_getmtime)

    def run(argv, timeout=None):
        if argv[:3] == ["cmux", "surface", "resume"]:
            return _Proc(f"{sid}\n")
        if argv[:2] == ["cmux", "send"]:
            return _Proc("OK")                    # sent, but nothing appended
        if argv[:2] == ["cmux", "read-screen"]:
            return _Proc("working...\n")          # the tail is not on the pane either
        return _Proc("")

    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict != P.VERIFIED, "an unnameable pre-existing transcript certified the send"


def test_a_short_multi_word_payload_still_verifies(P, tmp_path):
    """⛔ THE FALSE NEGATIVE THE BOUNDARY RULE CREATED (#1881 review, round 5 P1). `tail_marker` is
    WHITESPACE-STRIPPED, so a boundary test run against whitespace-preserving text could never match a
    marker with an internal space: `resume it`, `do it now`, `check pane` all became permanently
    unverifiable, and the operator's remedy invites a re-send of an order that arrived. Whole-value
    equality in the COMPACTED domain fixes both directions: the whitespace is gone from both sides.

    Fails on the round-4 bytes: they return False for every payload here."""
    for payload in ("resume it", "do it now", "check pane", "go on", "retry it"):
        f = tmp_path / "session.jsonl"
        f.write_text(json.dumps({"type": "message", "message": {"role": "user", "content": [
            {"type": "text", "text": payload}]}}) + "\n", encoding="utf-8")
        assert P.transcript_has_payload(str(f), payload) is True, payload


# ── the two CHANNELS need two rules: transcript value vs rendered surface (#1881 review P1) ────────

def test_a_short_payload_reaches_pane_only_on_a_rendered_surface(P):
    """⛔ `PANE_ONLY` WAS UNREACHABLE FOR EVERY SHORT ORDER (#1881 review P1). The whole-value rule is
    right for a transcript VALUE, but `screen_has_payload` applied it to a 200-line TUI render — which
    can never EQUAL a nine-character order. So `resume it` / `do it now` / `go on` fell to the
    catch-all arm, whose text diagnoses "cmux refused the send or delivered a PREFIX under load" — a
    truncation story with no evidence — instead of the one verdict whose remedy is "check the pane,
    press Enter, do not re-send".

    Fails on the pre-fix bytes: `screen_has_payload` returns False for every payload here."""
    for payload in ("resume it", "do it now", "check pane", "go on", "retry it", "ok"):
        assert P.screen_has_payload(f"Working... (turn started)\n{payload}\n> ", payload) is True, payload


def test_a_short_payload_on_the_pane_still_needs_a_TOKEN_BOUNDARY(P):
    """NON-VACUITY for the pane rule: relaxing it must not turn a substring into a match. `ok` inside
    `token` is not the order, and `continue` inside `continued` is not either."""
    assert P.screen_has_payload("assistant: checking the token now", "ok") is False
    assert P.screen_has_payload("I continued with the next item", "continue") is False
    assert P.screen_has_payload("resume items were skipped", "resume it") is False


def test_a_marker_is_never_stitched_across_two_appended_records(P, tmp_path):
    """⛔ THE JOINED CANDIDATE WAS STILL THERE (#1881 review P2). The comment said "each string value
    is its own candidate — never a joined one", but `candidates` still started with the WHOLE window
    `chunk`, and `compact()` strips newlines, so a >= 16-char marker could be stitched from the tail of
    one record and the head of the next. Two unrelated records the lane wrote are not a message it
    received.

    Fails on the pre-fix bytes: the window-join matches and a delivery verdict is reported."""
    # A PLAIN-TEXT transcript, where the join really was live: with JSONL syntax between two records
    # (`…"content":"` / `"}{…`) the stitched marker is unreachable by accident, which is exactly why
    # this survived — the class was closed on the record-shaped fixture and open on the other one.
    f = tmp_path / "session.txt"
    f.write_text("the pane first\nSO the check ran\n", encoding="utf-8")
    assert P.transcript_has_payload(str(f), "the pane first SO the check ran") is False


def test_session_files_state_of_an_unknown_id_is_UNKNOWN_not_absent(P):
    """⛔ `False` MEANS "A FILE WAS PROVEN ABSENT", WHICH LICENSES THE OFFSET-0 WINDOW (#1881 review
    P2). An id we were never given answers "could not look" (`None`) — today's only call site guards
    with `bool(session_id)`, but the read must not carry a licence it never earned."""
    assert P.session_files_state(None) is None
    assert P.session_files_state("") is None


def test_the_session_id_read_is_RETRIED_before_the_send(P):
    """⛔ ONE TRANSIENT `cmux` HICCUP MADE `VERIFIED` UNREACHABLE FOR A WHOLE DISPATCH (#1881 review
    P1). The id is resolved ONCE, before the send, and a single empty read (cmux is intermittently
    empty on a live pane — `orch-send.sh` retries its own footer four times for that reason) left
    `session_file` None for the run, so a message that really was submitted exited 6 and told the
    operator to re-send it. Nothing has been sent when this read runs, so a bounded retry costs no
    soundness.

    Fails on the pre-fix bytes: the first empty answer is returned as None and nothing is retried."""
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    reads = {"n": 0}

    def run(argv, timeout=None):
        reads["n"] += 1
        return _Proc("" if reads["n"] == 1 else f"{sid}\n")

    assert P.resolve_session_id("ws-1", run, sleep=_noop_sleep) == sid
    assert reads["n"] == 2


def test_a_nonzero_payload_send_states_its_cause_on_stderr(P, capsys):
    """⛔ THE CALLER'S ARM PROMISES THESE DIAGNOSTICS (#1881 review P2). `orch-send.sh`'s catch-all
    arm says "the checker's diagnostics below say which when it printed any" — naming exactly the
    branch it was written for, a `cmux` whose send exits 1 ("Access denied"). Nothing was written
    there, so the promise pointed at evidence that could not exist, and the operator could not tell
    "nothing was typed, safe to retry" from "a prefix landed, do not re-send"."""
    def run(argv, timeout=None):
        if argv[:2] == ["cmux", "send"]:
            proc = _Proc("", returncode=1)
            proc.stderr = "Access denied - only processes started inside cmux can connect"
            return proc
        return _Proc("")

    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.UNVERIFIED
    err = capsys.readouterr().err
    assert "cmux send exited 1" in err
    assert "Access denied" in err


def test_a_send_status_that_cannot_be_read_is_a_FAILURE_not_a_success(P):
    """⛔ `getattr(…, "returncode", 0)` DEFAULTED A MISSING STATUS TO SUCCESS (#1881 review P2). The
    comment above it said "only an explicit 0 passes" and the code did the opposite: a duck-typed
    process object from the `run` seam — the seam this module is built around — certified a send it
    never reported on. Wrong in the one direction this module may not fail in."""
    class _NoStatus:
        stdout = ""

    def run(argv, timeout=None):
        if argv[:2] == ["cmux", "send"]:
            return _NoStatus()
        return _Proc(LONG)                     # the payload IS on the pane

    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.UNVERIFIED, "a send with no readable status was treated as a success"
    assert verdict != P.PANE_ONLY, "a send we could not read was reasoned about as if it happened"


def test_a_direct_caller_gets_the_flattened_payload_too(P):
    """⛔ `flatten()` ONLY RAN IN `_main` (#1881 review P2). The module docstring offers `send_verified`
    as the shared seam and the PR body names its future adopters, so a direct caller still submitted a
    multi-line order ONE ENTER PER LINE — re-opening #1799 one call level below the only place that
    closed it, with the tail check certifying only the last fragment."""
    sent = []

    def run(argv, timeout=None):
        if argv[:2] == ["cmux", "send"]:
            sent.append(argv[-1])
            return _Proc("OK")
        return _Proc("")

    P.send_verified("ws-1", "line one\nline two\nTAIL", run=run, sleep=_noop_sleep, timeout_s=0)
    assert sent, "nothing was sent"
    assert "\n" not in sent[0], "a direct caller sent a multi-line payload"
    assert sent[0] == "line one line two TAIL"


def test_a_short_payload_is_not_certified_by_the_lanes_own_prose(P, tmp_path):
    """⛔ A TOKEN BOUNDARY WAS NOT ENOUGH (#1881 review, round 5 P1). The lane's own output is prose
    the check runs over, so `continue` was certified by "I will continue with the next item" and `ok`
    by "ok, moving on to the tests" — both a false VERIFIED for an order that was never submitted. A
    short marker must EQUAL a whole value, and splitting a message across two fields must not
    reassemble it into a match.

    Fails on the round-4 bytes: all three return True there."""
    prose = tmp_path / "prose.jsonl"
    prose.write_text(
        json.dumps({"type": "assistant", "content": "I will continue with the next item"}) + "\n"
        + json.dumps({"type": "assistant", "content": "ok, moving on to the tests"}) + "\n",
        encoding="utf-8")
    assert P.transcript_has_payload(str(prose), "continue") is False
    assert P.transcript_has_payload(str(prose), "ok") is False
    # Two unrelated fields must not be CONCATENATED into a match (the round-4 boundary rule did: the
    # joined candidate "soweshouldcheckthepanefirst" contains "thepanefirst"). Accepted residual: a
    # short payload that exactly EQUALS some field's value still matches (here "the pane first" equals
    # the record's `note`). That requires an exact coincidence with the lane's own field text, and
    # closing it fully would mean trusting only a named content field — a schema coupling this helper
    # deliberately does not take. Stated, not hidden.
    split = tmp_path / "split.jsonl"
    split.write_text(json.dumps({"content": "so we should check", "note": "the pane first"}) + "\n",
                     encoding="utf-8")
    assert P.transcript_has_payload(str(split), "the pane first SO the check ran") is False
    assert P.transcript_has_payload(str(split), "check the pane first") is False


def test_an_unreadable_existence_read_never_licenses_the_two_mb_window(P, tmp_path, monkeypatch):
    """⛔ "I COULD NOT LOOK" IS NOT "THERE IS NO FILE" (#1881 review, round 5 P2). `glob.glob`
    swallows OSError and returns [], so an unreadable directory read exactly like an empty one; the
    two baseline reads were the same glob back-to-back, so one short filesystem stall covered both,
    "no file" was inferred, and the search reopened at offset 0 over a pre-existing transcript. An
    existence read that errored is None here, and None never licenses the 2 MB window."""
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    home = tmp_path / "home"
    sessions = home / ".pi" / "agent" / "sessions" / "proj"
    sessions.mkdir(parents=True)
    sess = sessions / f"2026-09-29T12-00-00Z-{sid}.jsonl"
    sess.write_text('{"type":"user","text":"' + LONG + '"}\n', encoding="utf-8")
    monkeypatch.setenv("HOME", str(home))

    def unreadable(path):
        raise OSError("filesystem stalled")

    monkeypatch.setattr(P.os, "scandir", unreadable)

    def run(argv, timeout=None):
        if argv[:3] == ["cmux", "surface", "resume"]:
            return _Proc(f"{sid}\n")
        if argv[:2] == ["cmux", "send"]:
            return _Proc("OK")                    # sent, but nothing appended
        if argv[:2] == ["cmux", "read-screen"]:
            return _Proc("working...\n")
        return _Proc("")

    assert P.session_files_state(sid) is None
    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict != P.VERIFIED


def test_the_catch_all_verdict_text_does_not_assert_a_send_it_did_not_witness():
    """The catch-all arm also receives the case where `cmux send` ITSELF exited non-zero: nothing was
    typed, no pane or transcript was read, so "SENT" and "the TAIL is not on the pane" were claims
    about evidence never gathered, with a remedy (re-send) that fails identically. The text must name
    both branches so a later edit cannot silently restore the assertion."""
    with open(_ORCH_SEND, encoding="utf8") as fh:
        shell = fh.read()
    catch_all = shell.split("\n  *)", 1)[1]
    flat = " ".join(catch_all.split())
    assert "NOT VERIFIED AS DELIVERED" in flat
    assert "Either cmux refused the send" in flat
    assert "not on the pane and not in the transcript" not in flat


def test_a_transcript_created_by_this_send_can_still_verify(P, tmp_path, monkeypatch):
    """⛔ ONE RESOLUTION IS NOT ENOUGH (#1881 review P2). pi creates the session file on the first
    user message, so resolving the path only BEFORE the send made VERIFIED unreachable for a lane
    whose transcript this very send created — a permanent PANE_ONLY that then asserted a transcript
    read that had never happened. Re-resolved in the loop, with baseline 0 (the file did not exist
    when the send began, so every byte in it is this send's or later)."""
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    home = tmp_path / "home"
    sessions = home / ".pi" / "agent" / "sessions" / "proj"
    sessions.mkdir(parents=True)
    sess = sessions / f"2026-09-29T12-00-00Z-{sid}.jsonl"
    monkeypatch.setenv("HOME", str(home))

    def run(argv, timeout=None):
        if argv[:2] == ["cmux", "send"]:
            if argv[-1] != "\n":                 # the payload send CREATES the transcript
                sess.write_text('{"type":"user","text":"' + LONG + '"}\n', encoding="utf-8")
            return _Proc("OK")
        if argv[:2] == ["cmux", "read-screen"]:
            return _Proc("pane scrolled past the message")
        if argv[:3] == ["cmux", "surface", "resume"]:
            return _Proc(f"{sid}\n")
        return _Proc("")

    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.VERIFIED


def test_a_session_file_that_cannot_be_stat_ed_is_not_a_crash(P, tmp_path, monkeypatch):
    """⛔ THE STAT IS INSIDE THE GUARD (#1881 review P2). A session file vanishing between the glob
    and the `max(…, key=getmtime)` raised an OSError OUT of `resolve_session_file` → out of
    `send_verified` → the helper died with no stdout, and the caller reported "SENT BUT NOT
    VERIFIED" for a send that may well have landed. A file we cannot stat is a file we cannot name."""
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    home = tmp_path / "home"
    sessions = home / ".pi" / "agent" / "sessions" / "proj"
    sessions.mkdir(parents=True)
    (sessions / f"gone-{sid}.jsonl").write_text("x\n", encoding="utf-8")
    monkeypatch.setenv("HOME", str(home))

    def boom(path):
        raise OSError("vanished between glob and stat")

    monkeypatch.setattr(P.os.path, "getmtime", boom)

    def run(argv, timeout=None):
        if argv[:3] == ["cmux", "surface", "resume"]:
            return _Proc(f"{sid}\n")
        return _Proc("")

    assert P.resolve_session_file("ws-1", run) is None


def test_the_pane_only_text_does_not_assert_a_transcript_that_was_never_read():
    """The shell's PANE_ONLY arm claimed "the lane's transcript shows no such message" even when NO
    transcript could be resolved — a claim about evidence that was never read, attached to a remedy
    that invites a duplicate order. The text must name both branches."""
    with open(_ORCH_SEND, encoding="utf8") as fh:
        shell = fh.read()
    pane_only = shell.split("PANE_ONLY)", 1)[1].split("*)", 1)[0]
    flat = " ".join(pane_only.split())
    assert "or no transcript could be consulted at all" in flat


def test_a_previous_identical_message_does_not_certify_a_later_send(P, tmp_path):
    """⛔ OCCURRENCE IDENTITY (#1881 review P1). The transcript lookup was "is the marker anywhere in
    the last 2 MB", which on a live lane spans days — so a standing order, a nudge, or the retry the
    script's own recovery text prescribes certifies a LATER truncated send. Only bytes appended after
    the pre-send baseline may match."""
    f = tmp_path / "session.jsonl"
    f.write_text('{"type":"user","text":"' + LONG + '"}\n')
    baseline = f.stat().st_size
    # The SAME payload is already there from long ago: with the baseline it proves nothing.
    assert P.transcript_has_payload(str(f), LONG, since_offset=baseline) is False
    # ...and it would still "match" without the baseline, which is the defect being closed.
    assert P.transcript_has_payload(str(f), LONG) is True
    with open(f, "a", encoding="utf-8") as fh:
        fh.write(LONG + "\n")
    assert P.transcript_has_payload(str(f), LONG, since_offset=baseline) is True


def test_a_rolled_transcript_fails_closed(P, tmp_path):
    f = tmp_path / "session.jsonl"
    f.write_text(LONG + "\n")
    # A baseline PAST the current size means the file rolled between the readings; the positions are
    # not comparable, so nothing may be certified.
    assert P.transcript_has_payload(str(f), LONG, since_offset=f.stat().st_size + 5000) is False


def test_a_dropped_enter_is_reported_as_submit_failed_not_as_pane_only(P):
    # ⛔ PIN AGE, STATED (#1881 review, round 3): this pin belongs to the ROUND-1 fix (the raised
    # Enter), and it passes against those pre-fix bytes' successor — it does NOT discriminate the
    # round-3 change, whose residual was the missing NON-ZERO-EXIT arm. That arm's pin is
    # `test_a_nonzero_enter_exit_is_a_dropped_enter` below.
    """⛔ `entered` MUST DECIDE THE VERDICT (#1881 review P2). It was assigned, set to False on a
    dropped Enter, and never READ — a "recorded" flag next to a comment claiming it decides, which is
    how the P0 re-opens the moment someone adds a pane shortcut. A dropped Enter is not the softer
    `PANE_ONLY` ("typed, maybe awaiting flush"): submission was never ATTEMPTED, and the operator's
    remedy is to submit in that pane — never to re-send a message already in the composer."""
    def run(argv, timeout=None):
        if argv[:2] == ["cmux", "send"]:
            run.n = getattr(run, "n", 0) + 1
            if run.n >= 2:                       # the terminating Enter
                raise RuntimeError("cmux send failed")
            return _Proc("OK")
        if argv[:2] == ["cmux", "read-screen"]:
            return _Proc(f"working...\n{LONG}\n")
        return _Proc("")

    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.SUBMIT_FAILED
    assert verdict != P.PANE_ONLY


def test_the_verify_window_meets_the_measured_transcript_flush_floor(P):
    """⛔ 30 s WAS BELOW THIS REPO'S OWN MEASUREMENT (#1881 review P2). `ask-owner.py` measured a send
    at T landing at T+53 s on an ~18 MB session and set `LAND_TIMEOUT_S = 90` for that reason; a 30 s
    window answers the same question about the SAME file with less patience than the code that
    measured it, and reports arrival as "SENT BUT NOT SUBMITTED" — whose remedy invites a re-send."""
    assert P.DEFAULT_VERIFY_TIMEOUT_S >= 90.0
    with open(_ORCH_SEND, encoding="utf8") as fh:
        shell = fh.read()
    assert "ORCH_SEND_VERIFY_TIMEOUT:-90" in shell, "the CLI default is below the measured floor"


def test_the_module_docstring_states_the_verdict_count_the_code_has(P):
    """⛔ PROSE THAT UNDERCOUNTS THE VERDICTS READS AS A RULE (#1881 review, note). The module's
    header is the normative statement a caller reads before wiring a verdict into a success branch —
    it said "there are **three** verdicts" while the code has FOUR, because `SUBMIT_FAILED` was added
    after the prose was written. A docstring that enumerates a set the code has outgrown invites the
    next reader to fold the extra state back into a neighbour (which is exactly the false-PASS shape
    this module exists to remove), so the count and the enumeration are pinned together here.

    Fails on the pre-fix text, which says three."""
    doc = P.__doc__ or ""
    assert "**three** verdicts" not in doc, "the header undercounts the verdicts"
    assert "**four** verdicts" in doc
    # The enumeration and the code must name the same set — a count that grows without the prose
    # (or prose that lists a state the code dropped) is the drift this pin exists to catch.
    for verdict in (P.VERIFIED, P.PANE_ONLY, P.UNVERIFIED, P.SUBMIT_FAILED):
        assert verdict in doc, f"{verdict} is missing from the module header's enumeration"


def test_the_test_module_header_does_not_restate_the_two_verdict_contract():
    """The suite's own header described the pre-#1881-review two-state contract (`VERIFIED` vs
    `UNVERIFIED`) long after the code grew `PANE_ONLY` and `SUBMIT_FAILED`. It is the first thing a
    person reads when deciding what these tests cover, so it must not teach the collapsed contract."""
    with open(os.path.abspath(__file__), encoding="utf-8") as fh:
        header = fh.read().split('"""', 2)[1]
    # ⛔ NORMALISE, THEN MATCH: the phrase spans a line break in the old header, so a plain
    # substring test passed against the very text it exists to forbid (verified against
    # `git show HEAD:scripts/test_cmux_payload.py` — it does). A pin that cannot fail on the
    # pre-fix text is not a pin.
    flat = " ".join(header.split())
    assert "around the two speech acts" not in flat, "the suite header teaches the collapsed contract"
    for verdict in ("VERIFIED", "PANE_ONLY", "UNVERIFIED", "SUBMIT_FAILED"):
        assert verdict in flat, f"the suite header does not name {verdict}"


# ── `check`: a saved screen is not a delivery verdict ────────────────────────

def test_check_does_not_exit_zero_for_a_pane_only_match(P, tmp_path):
    """⛔ EXIT 0 IS THE SUCCESS CHANNEL (#1881 review P2). A caller doing
    `cmux_payload.py check … && record_delivered` got "delivered" out of a surface match — the same
    false PASS this module exists to remove, reintroduced on the second subcommand. The pane cannot
    distinguish a submitted message from one sitting in the composer, so PANE_ONLY must not exit 0."""
    screen = tmp_path / "screen.txt"
    screen.write_text(f"working...\n{LONG}\n", encoding="utf-8")
    rc = P._main(["check", "--screen-file", str(screen), "--text", LONG])
    assert rc == 4, "PANE_ONLY must not be reported on the machine-readable success channel"


def test_check_exits_three_when_the_tail_is_absent(P, tmp_path):
    screen = tmp_path / "screen.txt"
    screen.write_text("working...\n" + LONG[:40] + "\n", encoding="utf-8")
    rc = P._main(["check", "--screen-file", str(screen), "--text", LONG])
    assert rc == 3


def test_send_unverified_when_only_a_prefix_landed(P):
    run = _fake_cmux(LONG[: len(LONG) // 3])
    verdict, screen = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.UNVERIFIED
    assert screen == LONG[: len(LONG) // 3]


def test_send_unverified_when_the_screen_cannot_be_read(P):
    def run(argv, timeout=None):
        raise RuntimeError("cmux down")

    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.UNVERIFIED


def test_send_unverified_when_send_itself_fails(P):
    def run(argv, timeout=None):
        if argv[:2] == ["cmux", "send"]:
            raise RuntimeError("access denied")
        return _Proc("")

    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.UNVERIFIED


def test_send_verified_from_the_transcript_when_the_pane_scrolled(P, tmp_path, monkeypatch):
    """The transcript is the second source: a long pane can scroll the tail off."""
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    home = tmp_path / "home"
    sessions = home / ".pi" / "agent" / "sessions" / "proj"
    sessions.mkdir(parents=True)
    sess = sessions / f"2026-09-29T12-00-00Z-{sid}.jsonl"
    sess.write_text('{"type":"user","text":"earlier"}\n')
    monkeypatch.setenv("HOME", str(home))

    base = _fake_cmux("pane scrolled past the message", surface_out=f"{sid}\n")
    inner = base

    def run(argv, timeout=None):
        proc = inner(argv, timeout)
        if argv[:2] == ["cmux", "send"] and argv[-1] != "\n":
            with open(sess, "a", encoding="utf-8") as fh:
                fh.write(LONG + "\n")
        return proc

    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.VERIFIED


def test_empty_payload_never_reports_verified(P):
    run = _fake_cmux("anything at all")
    verdict, _ = P.send_verified("ws-1", "", run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.UNVERIFIED


def test_verify_flattens_the_payload_before_sending(P, monkeypatch):
    """⛔ `flatten` was DEAD CODE while every caller passed the raw body (#1881 review P1). A newline
    in a `cmux send` payload is an Enter, so a multi-line order is submitted line by line — each line
    its own independent chance at the #1187 truncation — while the tail marker can only ever certify
    the LAST one: a lost MIDDLE line verified. The CLI must send the flat form."""
    sent = {}
    pane = tmp_path_screen = None
    marker = "TAIL-SENTINEL"

    def run(argv, timeout=None):
        if argv[:2] == ["cmux", "send"]:
            sent.setdefault("payloads", []).append(argv[-1])
            return _Proc("OK")
        if argv[:2] == ["cmux", "read-screen"]:
            return _Proc("")
        return _Proc("")

    monkeypatch.setattr(P, "_default_run", lambda argv, timeout=45: run(argv, timeout))
    P._main(["verify", "--workspace", "ws-1", "--text", "line one\nline two\n" + marker,
             "--timeout", "0"])
    payloads = sent.get("payloads") or []
    assert payloads, "nothing was sent"
    body = payloads[0]
    assert "\n" not in body, "the CLI sent a multi-line payload: each newline is its own Enter"
    assert body == f"line one line two {marker}"


# ── end-to-end: the orchestrator send path (scripts/orch-send.sh) ──────────────
#
# The helper is only the fix if the path that actually dispatches lanes USES it.
# These drive the real script with a PATH-shimmed `cmux`, so the wiring (send +
# verify + exit code) is pinned, not just the module.

def _fake_cmux_path(tmp_path, screen_text, session=None, sid=None):
    """A PATH-shimmed `cmux`. When `session` is given, a payload send APPENDS to it and
    `surface resume show` answers `sid` — i.e. the fake SUBMITS the message, which is what a delivery
    verdict now requires (#1881 review P0). Without it the fake only puts text on the surface, which
    is the composer state, not a submission."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    screen = tmp_path / "screen.txt"
    screen.write_text(screen_text)
    cmux = bindir / "cmux"
    # ⛔ THE `--lines 10` ARM IS LOAD-BEARING (fix-lane review, 2026-10-16). The PRE-FIX
    # orch-send.sh probed the pane with `read-screen --lines 10` and reported CONSUMED when
    # it matched `Working|Steering|queued message`. Without an arm for that window the fake
    # falls through to the footer catch-all (the repo path), the old heuristic can never
    # match, and a prefix test fails pre-fix for the WRONG reason — it never reaches the
    # false-PASS branch it exists to pin. Serving the pane for `--lines 10` reproduces the
    # measured #1187 shape: turn STARTED, tail ABSENT, old code says CONSUMED (exit 0).
    cmux.write_text(textwrap.dedent('''\
        #!/usr/bin/env bash
        args="$*"
        case "$args" in
          *"resume show"*) echo "${FAKE_SESSION_SID:-}" ;;
          *read-screen*"--lines 200"*) cat "${FAKE_SCREEN_FILE:-/dev/null}" ;;
          *read-screen*"--lines 10"*) cat "${FAKE_SCREEN_FILE:-/dev/null}" ;;
          *read-screen*) echo "/Users/test/Documents/GitHub/agent-infra" ;;
          *send*)
            # FAKE_SESSION_JSON appends a PRE-ENCODED JSONL record instead of the raw argv — the
            # shape a real session transcript has, where a quote in the text is written \" and
            # a raw-byte comparison of a quoted tail can never match (#1881 review P1/P2).
            if [ -n "${FAKE_SESSION_JSON:-}" ]; then cat "$FAKE_SESSION_JSON" >>"${FAKE_SESSION_FILE:?}";
            elif [ -n "${FAKE_SESSION_FILE:-}" ]; then printf '%s\\n' "$args" >>"$FAKE_SESSION_FILE"; fi
            echo "OK surface:1 workspace:1" ;;
          *"workspace list"*) echo '{"workspaces":[]}' ;;
          *) echo "" ;;
        esac
        '''))
    cmux.chmod(cmux.stat().st_mode | stat.S_IEXEC)
    return bindir, screen


def _run_orch_send(bindir, screen, message, home=None, session=None, sid=None, script=None,
                   session_json=None):
    env = dict(os.environ)
    env["PATH"] = f"{bindir}{os.pathsep}{env['PATH']}"
    env["FAKE_SCREEN_FILE"] = str(screen)
    env["ORCH_SEND_VERIFY_TIMEOUT"] = "0"
    if home:
        env["HOME"] = str(home)
    else:
        # A CLEAN RUNNER'S HOME: no `~/orchestrator/brief-gate.sh` to fall back to (#1881 review P1).
        env["HOME"] = str(bindir.parent / "home")
        (bindir.parent / "home").mkdir(exist_ok=True)
    env = _runner_env(env)
    if session:
        env["FAKE_SESSION_FILE"] = str(session)
    if sid:
        env["FAKE_SESSION_SID"] = sid
    if session_json:
        env["FAKE_SESSION_JSON"] = str(session_json)
    return subprocess.run(["bash", script or _ORCH_SEND, "ws-1", "TEST", message],
                          capture_output=True, text=True, env=env, timeout=60)


def _submitting_lane(tmp_path, screen_text):
    """A fixture whose fake cmux SUBMITS: a session transcript exists, and each payload send appends
    to it. This is the only shape in which a delivery verdict can legitimately be CONSUMED."""
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    home = tmp_path / "home"
    sessions = home / ".pi" / "agent" / "sessions" / "proj"
    sessions.mkdir(parents=True)
    session = sessions / f"2026-09-29T12-00-00Z-{sid}.jsonl"
    session.write_text('{"type":"user","text":"an earlier message"}\n')
    bindir, screen = _fake_cmux_path(tmp_path, screen_text, session=session, sid=sid)
    return bindir, screen, home, session, sid


def test_orch_send_reports_consumed_only_when_the_tail_is_verified(tmp_path):
    # Same started-turn line as the prefix test: the difference between the two cases must
    # be the TAIL, never the turn signal (which is present in both).
    # The lane SUBMITS here (its transcript records the send), which is what CONSUMED certifies.
    bindir, screen, home, session, sid = _submitting_lane(
        tmp_path, f"Working... (turn started)\n{LONG}\n")
    r = _run_orch_send(bindir, screen, LONG, home=home, session=session, sid=sid)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "CONSUMED" in r.stdout
    assert "NOT VERIFIED" not in r.stdout


def test_orch_send_does_not_report_consumed_when_the_enter_was_lost(tmp_path):
    """⛔ The P0 through the REAL script (#1881 review). The pane shows the payload because the
    composer renders what it holds; the transcript shows NOTHING because nothing was submitted. The
    old code grepped the pane, so this was a CONSUMED exit 0 — an order loss reported as delivered."""
    bindir, screen = _fake_cmux_path(tmp_path, f"Working... (turn started)\n{LONG}\n")
    r = _run_orch_send(bindir, screen, LONG)          # no session => nothing is ever appended
    assert r.returncode == 6, r.stdout + r.stderr
    assert "CONSUMED" not in r.stdout
    assert "NOT SUBMITTED" in r.stdout


def test_orch_send_does_not_report_ok_over_a_prefix(tmp_path):
    """The measured #1187 shape: the head arrived, the tail did not, `cmux` said OK.

    The pane carries a started-turn line (`Working`) as well as the prefix — that is what
    made the pre-fix path a FALSE PASS rather than a refusal: `Working` is the signal the
    old consumption check grepped for, and a truncated prefix starts a turn, so "a turn has
    started" was satisfied while the tail was gone. A prefix with NO turn line would have
    been refused by the OLD code too, so it would pin nothing about the fix.
    """
    bindir, screen = _fake_cmux_path(tmp_path, "Working... (turn started)\n" + LONG[: len(LONG) // 3] + "\n")
    r = _run_orch_send(bindir, screen, LONG)
    assert r.returncode == 6, r.stdout + r.stderr
    assert "NOT VERIFIED" in r.stdout


def _farmed_copy(tmp_path, checker_body=None):
    """A FARMED copy of the sender: the script at `<root>/scripts/orch-send.sh`, and its checker
    sibling at `<root>/scripts/lib/cmux_payload.py` — present only when `checker_body` is given.

    `SCRIPTS` is derived from the script's OWN location, so a copy in its own root is how a farm
    missing a sibling is reproduced without touching this checkout.

    ⛔ AND IT MUST CARRY THE BRIEF GATE TOO (#1881 review P1, BLOCKING). The copy reproduced a farm
    that had never existed: `orch-send.sh` resolves `orchestrator-harness/brief-gate.sh` beside
    itself (fallback 2 of three) and runs it BEFORE target resolution and BEFORE the checker guard
    these arms pin, so with no gate in the root all three arms exited **78** — on the CI runner,
    where `AGENT_INFRA_PATH` is unset and `$HOME/orchestrator` does not exist. They passed on this
    laptop only because fallback 3 found the operator's own `~/orchestrator/brief-gate.sh`: a
    box-dependent green, in the suite whose whole purpose is to be runnable by CI.

    The REAL gate is copied, not stubbed, so the arms still exercise the real validation and the
    fixtures still have to be conforming briefs.
    """
    root = tmp_path / "farmed"
    (root / "scripts").mkdir(parents=True)
    script = root / "scripts" / "orch-send.sh"
    with open(_ORCH_SEND, encoding="utf8") as fh:
        script.write_text(fh.read())
    (root / "scripts" / "orchestrator-harness").mkdir()
    (root / "scripts" / "orchestrator-harness" / "brief-gate.sh").write_text(
        open(_BRIEF_GATE, encoding="utf8").read(), encoding="utf8")
    if checker_body is not None:
        (root / "scripts" / "lib").mkdir()
        (root / "scripts" / "lib" / "cmux_payload.py").write_text(checker_body)
    return script


def _runner_env(env):
    """The env a CLEAN CI runner has — no `AGENT_INFRA_PATH`, no `$O`, an empty `$HOME` (#1881
    review P1). Without this the farmed-copy arms pass on a developer box and redden on the runner."""
    env.pop("AGENT_INFRA_PATH", None)
    env.pop("O", None)
    return env


def test_orch_send_refuses_when_the_checker_is_missing(tmp_path):
    """⛔ P2 (#1881 review): the helper OWNS the send, so a farmed copy WITHOUT its checker
    sibling means NOTHING was dispatched. The pre-fix code fell into the `UNVERIFIED` arm, which
    begins "SENT BUT NOT VERIFIED" — false — and prescribes a re-send that would fail identically
    forever. The refusal must say what is missing, and the send must not happen at all."""
    script = _farmed_copy(tmp_path)                     # no lib/cmux_payload.py
    sent_log = tmp_path / "sent.log"
    bindir, screen = _fake_cmux_path(tmp_path, "Working... (turn started)\n")
    r = _run_orch_send(bindir, screen, LONG, script=script, session=sent_log)
    # ⛔ NOT 78: the farmed copy carries the brief gate beside itself, so a CLEAN RUNNER (no
    # AGENT_INFRA_PATH, no $HOME/orchestrator) reaches the checker guard this arm pins. 78 is the
    # "brief-gate.sh not found" refusal, which made this arm red for a reason unrelated to its name.
    assert r.returncode != 78, r.stdout + r.stderr
    assert r.returncode == 7, r.stdout + r.stderr
    assert "NOT SENT" in r.stdout
    # The pre-fix wording is the false claim this pin exists to forbid.
    assert "SENT BUT NOT VERIFIED" not in r.stdout
    # ... and it names the actual cause instead of prescribing a doomed re-send.
    assert "missing:" in r.stdout and "cmux_payload.py" in r.stdout
    # Nothing was dispatched: the fake `cmux` records a payload send by appending here.
    assert not sent_log.exists() or not sent_log.read_text().strip(), sent_log.read_text()


def test_orch_send_surfaces_a_crashing_checkers_stderr(tmp_path):
    """The other half of the P2: the checker's stderr used to be discarded into `/dev/null`, so an
    operator saw only "SENT BUT NOT VERIFIED" and had no cause. It is kept and shown."""
    script = _farmed_copy(
        tmp_path,
        checker_body="import sys\nsys.stderr.write('Traceback: fixture checker exploded\\n')\n"
                     "sys.exit(3)\n",
    )
    bindir, screen = _fake_cmux_path(tmp_path, "Working... (turn started)\n")
    r = _run_orch_send(bindir, screen, LONG, script=script)
    # No verdict on stdout => not delivered (the unchanged contract).
    assert r.returncode == 6, r.stdout + r.stderr
    assert "NOT VERIFIED" in r.stdout
    assert "checker diagnostics:" in r.stdout
    assert "fixture checker exploded" in r.stdout


def test_orch_send_reports_a_failed_enter_distinctly_from_pane_only(tmp_path):
    """⛔ A FAILED ENTER IS NOT "typed, awaiting flush" (#1881 review P2). The terminating Enter
    raising means submission was never ATTEMPTED, and the payload is sitting in that pane's composer:
    telling the operator to re-send duplicates an order that is already there. The script must say so
    and must name the state, so a client switching on the verdict string cannot confuse the two."""
    script = _farmed_copy(tmp_path, checker_body="print('SUBMIT_FAILED')\n")
    bindir, screen = _fake_cmux_path(tmp_path, f"Working... (turn started)\n{LONG}\n")
    r = _run_orch_send(bindir, screen, LONG, script=script)
    assert r.returncode == 6, r.stdout + r.stderr
    assert "SENT BUT NOT SUBMITTED" in r.stdout
    assert "CONSUMED" not in r.stdout
    # The cause, and the remedy that does NOT duplicate the order.
    assert "Enter FAILED" in r.stdout
    assert "IN THAT PANE" in r.stdout


def test_orch_send_verifies_a_quoted_tail_against_a_real_jsonl_transcript(tmp_path):
    """⛔ END-TO-END FOR THE JSON ESCAPE (#1881 review P1/P2), through the REAL `orch-send.sh`.

    A lane's session transcript is JSONL: the payload's text lives inside a JSON string, so its `"`
    arrives as `\\"`. With a raw-byte comparison this dispatch could never be CONSUMED — exit 6 and a
    "re-send" invitation, for a message that WAS delivered. The fixture appends the encoded record,
    which is what a submitting lane writes."""
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    home = tmp_path / "home"
    sessions = home / ".pi" / "agent" / "sessions" / "proj"
    sessions.mkdir(parents=True)
    session = sessions / f"2026-09-29T12-00-00Z-{sid}.jsonl"
    session.write_text('{"type":"user","content":"an earlier message"}\n', encoding="utf-8")
    record = tmp_path / "record.jsonl"
    record.write_text(json.dumps({"type": "user", "content": QUOTED}) + "\n", encoding="utf-8")

    bindir, screen = _fake_cmux_path(tmp_path, f"Working... (turn started)\n{QUOTED}\n",
                                     session=session, sid=sid)
    r = _run_orch_send(bindir, screen, QUOTED, home=home, session=session, sid=sid,
                       session_json=record)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "CONSUMED" in r.stdout
    assert "NOT SUBMITTED" not in r.stdout


# ── the surface passthrough (#1187 follow-up) ─────────────────────────────────
#
# `send_verified` addressed `--workspace` only, so a caller that had ALREADY resolved a specific
# surface could not adopt the checker without silently retargeting its message at whatever surface
# cmux considers active. Every arm of the send/verify sequence must carry the caller's target.

def test_send_verified_forwards_the_callers_surface(P):
    seen = []

    def run(argv, timeout=None):
        seen.append(list(argv))
        return _Proc("")

    P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0, surface="surf-9")
    assert seen, "nothing was sent"
    for argv in seen:
        assert "--surface" in argv, f"an arm lost the caller's surface: {argv}"
        assert argv[argv.index("--surface") + 1] == "surf-9", argv
    # The send, the terminating Enter, the session lookup and the pane read all reach the same target.
    kinds = {argv[1] for argv in seen}
    assert kinds == {"send", "read-screen", "surface"}, kinds


def test_send_verified_without_a_surface_is_unchanged(P):
    """The default must be byte-identical to the pre-fix argv, or every existing caller moves."""
    seen = []

    def run(argv, timeout=None):
        seen.append(list(argv))
        return _Proc("")

    P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert seen
    for argv in seen:
        assert "--surface" not in argv, argv


def test_verify_cli_forwards_a_surface(P, monkeypatch):
    seen = []

    def run(argv, timeout=45):
        seen.append(list(argv))
        return _Proc("")

    monkeypatch.setattr(P, "_default_run", run)
    P._main(["verify", "--workspace", "ws-1", "--surface", "surf-9",
             "--text", LONG, "--timeout", "0"])
    assert seen
    assert all("--surface" in argv for argv in seen), seen


# ── end-to-end: the cadence FLOOR (scripts/cadence-nudge.sh) ───────────────────
#
# The floor wrote `delivered=yes` UNCONDITIONALLY: `cmux send` returned OK, and the receipt was
# printed with no reference to the exit code and no verification at all. Under #1187 that receipt
# certified a pane that had received only a prefix — and the log is what the next reader takes as
# the receipt. The readers that actually exist are named below, and this is a file whose subject is a
# claim that must name its evidence — so do not grow the list without opening the file. Cite them by
# PATTERN, not by line number: this block already rotted once, in the very commit that added it, when
# a header/lock edit above the due read shifted its number from 84 to 117.
#   * `scripts/cadence-nudge.sh`, the `last=$(sed -n 's/.*NUDGE at=…` due read — the floor's own clock;
#   * `scripts/orchestrator-heartbeat.sh`, the `LAST=$(grep -o 'NUDGE at=[0-9]*' "$LOG" …)` rate limit —
#     the TICK's clock; it reads `NUDGE at=` and ignores `delivered=`;
#   * a human reading the log when a beat is missing.
# NOT `scripts/session-postmortem.sh`: it turns a pi session `*.jsonl` into a retrospective and
# contains no reference to this log, `NUDGE`, `delivered` or `$STATE` (verified: 0 matches). Naming it
# was a claim about an evidence source that does not exist — the defect class this PR removes.
# These tests drive the REAL script.

_NUDGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cadence-nudge.sh")
_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
# The interpreter the floor hardcodes (`[ -x /usr/bin/python3 ]`). A runner without it silently takes
# the NO-USABLE-CHECKER path, so every checker-branch test must SKIP rather than fail with a message that
# says nothing about the cause (#3795 review P2).
_FLOOR_PY = "/usr/bin/python3"


def _cadence_home(tmp_path, screen_text, previous_line):
    """A farmed copy of the floor, with the pane it resolves and the state it reads."""
    home = tmp_path / "home"
    scripts = home / ".pi" / "agent" / "scripts"
    (scripts / "lib").mkdir(parents=True)
    state = home / ".pi" / "agent" / "state"
    state.mkdir(parents=True)
    # The floor's own SCRIPTS root, exactly as it is farmed.
    (scripts / "cadence-nudge.sh").write_text(open(_NUDGE, encoding="utf-8").read(),
                                              encoding="utf-8")
    for name in ("objective.py",):
        (scripts / name).write_text(open(os.path.join(_SCRIPTS_DIR, name), encoding="utf-8").read(),
                                    encoding="utf-8")
    (scripts / "lib" / "cmux_payload.py").write_text(
        open(os.path.join(_SCRIPTS_DIR, "lib", "cmux_payload.py"), encoding="utf-8").read(),
        encoding="utf-8")
    (scripts / "lib" / "beat-pair.sh").write_text(
        open(os.path.join(_SCRIPTS_DIR, "lib", "beat-pair.sh"), encoding="utf-8").read(),
        encoding="utf-8")
    # The floor sources the fleet's ONE process-identity rule (#1178) for the lock predicate, and the
    # farm ships it in `lib_srcs` (pi-bootstrap/setup.sh). Without it the predicate degrades to the
    # fail-closed "unknown" answer and the dead-holder arm is unreachable, so the fixture must carry it
    # exactly as a farmed box does.
    (scripts / "lib" / "pid-identity.sh").write_text(
        open(os.path.join(_SCRIPTS_DIR, "lib", "pid-identity.sh"), encoding="utf-8").read(),
        encoding="utf-8")
    # The pane the floor sends to is READ from the tick, never hardcoded here.
    (scripts / "orchestrator-heartbeat.sh").write_text(
        'ORCH_WS="WS-FAKE"\nORCH_SURFACE="SURF-FAKE"\n', encoding="utf-8")
    (state / "orchestrator-heartbeat.log").write_text(previous_line, encoding="utf-8")
    (state / "objective.last").write_text("OBJECTIVE: fixture\nobj-line\nres-line\n",
                                          encoding="utf-8")

    bindir = tmp_path / "bin"
    bindir.mkdir()
    cmux = bindir / "cmux"
    cmux.write_text(textwrap.dedent('''\
        #!/usr/bin/env bash
        args="$*"
        case "$args" in
          *"resume show"*)
            # ⛔ A cmux THAT DOES NOT KNOW `--surface` ON THE `resume` SCOPE (#3795 review cycle 12,
            # P1). Every other fake in this file answers `resume show` IRRESPECTIVE of the flag, so
            # `cmux_payload.py`'s workspace-only fallback was unreachable from the floor's own tests
            # and the receipt it produces was never measured (`rg 'retrying workspace-only'` = 0).
            # `FAKE_SURFACE_REJECTED=1` is that box: refuse the flag (non-zero, no id) and still
            # answer the workspace form, which is exactly what a flag-rejecting cmux does.
            case " $args " in
              *" --surface "*) [ -z "${FAKE_SURFACE_REJECTED:-}" ] || exit 2 ;;
            esac
            echo "${FAKE_SESSION_SID:-}" ;;
          *read-screen*) cat "${FAKE_SCREEN_FILE:-/dev/null}" ;;
          *send*)
            # FAKE_ENTER_REJECTED=1: this pane REFUSES the bare-Enter retry (payload exactly a
            # bare newline) while accepting the payload send. A refused retry must still be reported
            # as ATTEMPTED (#3795 review cycle 13, P2) -- the earlier `=no` arm made it read as
            # never tried. (Backslash-n is doubled so PYTHON does not turn it into a real newline:
            # the generated script compares against the two literal characters cmux is sent.)
            case "$args" in *' \\n') [ -z "${FAKE_ENTER_REJECTED:-}" ] || exit 3 ;; esac
            if [ -n "${FAKE_SESSION_FILE:-}" ]; then printf '%s\\n' "$args" >>"$FAKE_SESSION_FILE"; fi
            echo "OK surface:19 workspace:19" ;;
          *) echo "" ;;
        esac
        '''))
    cmux.chmod(cmux.stat().st_mode | stat.S_IEXEC)
    screen = tmp_path / "screen.txt"
    screen.write_text(screen_text, encoding="utf-8")
    return home, bindir, screen, state


def _run_cadence_nudge(home, bindir, screen, session=None, sid=None, checker=True,
                       stub_verdict=None, verify_timeout=None, extra_env=None):
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["PATH"] = f"{bindir}{os.pathsep}{env['PATH']}"
    env["FAKE_SCREEN_FILE"] = str(screen)
    env["CADENCE_NUDGE_VERIFY_TIMEOUT"] = verify_timeout if verify_timeout is not None else "0"
    if session:
        env["FAKE_SESSION_FILE"] = str(session)
    if sid:
        env["FAKE_SESSION_SID"] = str(sid)
    env = _runner_env(env)
    script = home / ".pi" / "agent" / "scripts" / "cadence-nudge.sh"
    if not checker:
        # The farmed copy lost its checker: the floor must still send, and must still refuse to
        # certify what it could not check.
        (home / ".pi" / "agent" / "scripts" / "lib" / "cmux_payload.py").unlink()
    if extra_env:
        env.update({k: str(v) for k, v in extra_env.items()})
    if stub_verdict is not None:
        # ⛔ DRIVE THE VERDICT MAPPING DIRECTLY (#3795 review P2). The `case` in the floor decides
        # what a `delivered=` value MEANS, and only the VERIFIED and UNVERIFIED arms were pinned. A
        # later "simplification" to `VERIFIED|PANE_ONLY) delivered="yes"` reds no test without these.
        # The stub ADVERTISES `--surface` on `--help` because the floor probes capability before it
        # commits to the checker path (#3795 review cycle 3): a stand-in for the CURRENT checker must
        # look like one, or the floor correctly takes the raw-send path instead.
        stub = (home / ".pi" / "agent" / "scripts" / "lib" / "cmux_payload.py")
        stub.write_text("import sys\n"
                        "if '--help' in sys.argv:\n"
                        "    print('usage: cmux_payload.py verify --workspace W [--surface S]')\n"
                        "    sys.exit(0)\n"
                        "print(%r)\n"
                        "sys.exit(%d)\n"
                        % (stub_verdict, 0 if stub_verdict == "VERIFIED" else 3),
                        encoding="utf-8")
    return subprocess.run(["bash", str(script)], capture_output=True, text=True, env=env,
                          timeout=120)


def _new_nudge_lines(state, seed):
    """The `NUDGE at=` lines THIS run wrote. The seeded line is a PRIOR, legitimate receipt: asserting
    over the whole file would fail on it and say nothing about what this send claimed."""
    log = (state / "orchestrator-heartbeat.log").read_text(encoding="utf-8")
    appended = log[len(seed):] if log.startswith(seed) else log
    return [line for line in appended.splitlines() if "NUDGE at=" in line], appended


def _seeded_log(seconds_ago):
    import time as _t
    return ("NUDGE at=%d delivered=yes (cadence-floor) gap=1m queue=[] alerts=[] ask=[]\n"
            % (int(_t.time()) - seconds_ago))


# ── the LOCK: who holds it, and how it may be reclaimed (#3795 review P1 + cycle 2 P1) ──────
#
# This block had NO test at all, and both defects in it were therefore mutation-invisible. They were
# measured failures in OPPOSITE directions, so a test for one is worthless without the other:
#   * age-only takeover RACED a live nudge — the critical section grew to ~413 s while the bound
#     stayed at 360 s, so a second tick rmdir'd a lock whose owner was still typing and both sent a
#     heartbeat seconds apart;
#   * pid-only takeover WEDGED THE FLOOR FOREVER — a killed nudge leaves the pid file, a recycled pid
#     then "is alive" for ever, every tick took the loser path, and nothing was written. Permanently
#     dead with a clean log. (The repo already ruled on this shape: `auto-rail.sh` — "a pid is not an
#     identity".)
# The four arms below are the contract: a genuine live holder is not raced; a pid that is not this
# script is not a holder; an unowned young lock is held (fail-closed on the mkdir→pid window); and a
# genuine holder past the absolute ceiling IS reclaimed, so nothing can wedge the floor permanently.

def _lock(state, pid=None, age_s=None, pid_inside=False):
    """Create the floor's lock. `pid` goes to the SIBLING file (this version) or inside (old format)."""
    lock = state / "cadence-nudge.lock"
    lock.mkdir(exist_ok=True)
    if pid is not None:
        target = lock / "pid" if pid_inside else state / "cadence-nudge.lock.pid"
        target.write_text(f"{pid}\n", encoding="utf-8")
    if age_s is not None:
        t = time.time() - age_s
        os.utime(lock, (t, t))
    return lock


def _live_holder_that_is_not_a_nudge(tmp_path):
    """A live pid whose argv does NOT name cadence-nudge.sh — a recycled or foreign pid."""
    return subprocess.Popen(["sleep", "120"])


def _live_holder_named_like_the_floor(tmp_path):
    """A live process whose argv NAMES cadence-nudge.sh — what the identity check must accept.

    `ps -o args=` must show the script name, so the binary is copied under that name rather than
    re-exec'ing with a patched argv (bash 3.2 on macOS has no `exec -a`).
    """
    fake = tmp_path / "cadence-nudge.sh"
    shutil.copy(shutil.which("sleep"), fake)
    return subprocess.Popen([str(fake), "300"])


def test_a_failed_surface_read_that_still_prints_an_id_is_not_qualified(P):
    """⛔ A REAL ID OUT OF A **FAILED** READ IS STILL NOT THIS SURFACE'S (#3795 review cycle 2, P2).

    `probe` returned a hardcoded `True` for the qualification flag, so a cmux that errors on
    `--surface` (rc=2) and still prints the WORKSPACE's session id was reported as
    surface-QUALIFIED — and that flag is the one fact `send_verified` relies on to deny the transcript
    arms. Measured before the fix: `qualified=True`, verdict `VERIFIED` — an id out of a failed read
    certifying a send. The empty-stdout shape was already pinned; this is the OTHER half, one fixture
    attribute away.
    """
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"

    def run(argv, timeout=None):
        if argv[:3] == ["cmux", "surface", "resume"] and "--surface" in argv:
            # Errors, but still prints an id — the shape a partial/older cmux produces.
            return _Proc(f"{sid}\n", returncode=2)
        if argv[:3] == ["cmux", "surface", "resume"]:
            return _Proc(f"{sid}\n")
        return _Proc("")

    got, qualified = P._resolve_session_id_qualified(
        "ws-1", run, sleep=_noop_sleep, surface="surf-9")
    assert got == sid, got
    assert qualified is False, (
        "an id out of a FAILED surface read was reported as the caller's own surface")


def test_a_surface_read_with_no_readable_status_cannot_award_qualification(P):
    """⛔ THE `returncode` DEFAULT IN `probe` IS THE SEND'S POLARITY, AND IT HAD NO PIN (#3795 review
    cycle 7, P2).

    `probe` reads `getattr(proc, "returncode", 1)` so that a `run` seam returning an object with no
    exit status is a FAILED read. That comment announces an invariant, and a mutation of exactly that
    default back to `0` left all 90 tests green: every fixture reaching `probe` used `_Proc`, which
    always sets `returncode`, so the announced polarity was mutation-INVISIBLE. The identical polarity
    at the payload send IS pinned
    (`test_a_send_status_that_cannot_be_read_is_a_FAILURE_not_a_success`); this is its mirror, one arm
    up. Without it, defaulting an unreadable status to success lets an id out of a read we could not
    trust award a SURFACE QUALIFICATION, and `send_verified` then takes its transcript baseline from
    another pane — the cross-pane mint this module exists to refuse.
    """
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"

    class _NoStatus:
        stdout = sid + "\n"                 # a real id, but no readable exit status

    def run(argv, timeout=None):
        if argv[:3] == ["cmux", "surface", "resume"] and "--surface" in argv:
            return _NoStatus()
        if argv[:3] == ["cmux", "surface", "resume"]:
            return _Proc(f"{sid}\n")
        return _Proc("")

    got, qualified = P._resolve_session_id_qualified(
        "ws-1", run, sleep=_noop_sleep, surface="surf-9")
    assert got == sid, got
    assert qualified is False, (
        "an id out of a read whose EXIT STATUS could not be read awarded a surface qualification")


def test_a_workspace_only_caller_is_unchanged_by_the_qualification_rule(P):
    """The qualification rule must not move a caller that named NO surface (every pre-#3795 caller,
    including `orch-send.sh`): there is no other surface to be confused with, so its argv AND its
    qualification stay exactly as they were."""
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    seen = []

    def run(argv, timeout=None):
        seen.append(list(argv))
        if argv[:3] == ["cmux", "surface", "resume"]:
            return _Proc(f"{sid}\n")
        return _Proc("")

    got, qualified = P._resolve_session_id_qualified("ws-1", run, sleep=_noop_sleep)
    assert got == sid
    assert qualified is True, "a workspace-only caller was downgraded by a surface-only rule"
    assert all("--surface" not in argv for argv in seen), seen


def test_cadence_nudge_does_not_race_a_live_holder_and_says_so(tmp_path):
    """A genuine live nudge holds its lock: this tick must decline, SEND NOTHING, and LOG the skip.

    The log line is half the contract: an invisible skip is how the floor died with a clean log.
    """
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    holder = _live_holder_named_like_the_floor(tmp_path)
    try:
        _lock(state, pid=holder.pid, age_s=60)        # young: well inside the ceiling
        sent = tmp_path / "SENT"
        r = _run_cadence_nudge(home, bindir, screen, session=sent)
        assert r.returncode == 0, r.stdout + r.stderr
        assert not sent.exists(), "raced a live holder and sent a second heartbeat"
        nudges, appended = _new_nudge_lines(state, seed)
        assert not nudges, "a skipped tick stamped a receipt:\n" + appended
        assert "lock-skip" in appended, (
            "the skip was silent — an invisible skip is how the floor dies with a clean log:\n" + appended)
        # The bound on the line is the CEILING: a genuine holder is reclaimed by age alone never, by the
        # 20-min ceiling only. If this ever reads `bound=6m` the holder arm was re-pointed at the short
        # grace, which is the mid-run reclaim measured as two receipts 4 s apart.
        assert "bound=20m" in appended, appended
    finally:
        holder.terminate()
        holder.wait(timeout=10)


def test_cadence_nudge_reclaims_a_lock_whose_pid_is_not_a_nudge(tmp_path):
    """⛔ THE P1: A RECYCLED OR FOREIGN PID MUST NOT WEDGE THE FLOOR FOR EVER.

    `kill -0` proves a pid EXISTS, never that it is the nudge that wrote it. With a pid-only guard, an
    unrelated long-lived process holding a recycled number silenced the floor permanently and
    silently. The lock here is old AND its pid is alive, so only the identity check can save it.
    """
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    holder = _live_holder_that_is_not_a_nudge(tmp_path)
    try:
        # ⛔ THE AGE IS THE WHOLE POINT: 500 s is PAST the 360 s grace (so a pid-only guard's `elif`
        # would not save it) and INSIDE the 20-min ceiling (so the bounded-reclaim arm does not rescue
        # it either). Only the IDENTITY check can reclaim this lock. Measured: at 3600 s (past the
        # ceiling) a pid-only guard also passes, which is exactly how a vacuous version of this test
        # was caught.
        _lock(state, pid=holder.pid, age_s=500)
        sent = tmp_path / "SENT"
        r = _run_cadence_nudge(home, bindir, screen, session=sent)
        assert r.returncode == 0, r.stdout + r.stderr
        assert sent.exists(), (
            "a lock whose pid is a LIVE UNRELATED process wedged the floor — the permanently-dead-"
            "with-a-clean-log state")
    finally:
        holder.terminate()
        holder.wait(timeout=10)


def test_cadence_nudge_reclaims_a_lock_past_the_ceiling_even_if_a_nudge_holds_it(tmp_path):
    """A genuine holder is not raced — but it is not immortal either.

    Past the absolute ceiling (2.7 timer intervals) its message is stale anyway, and a duplicate
    heartbeat is explicitly not the dangerous duplicate a duplicate lane ORDER is. Without this arm a
    genuinely hung checker would hold the floor for ever, which is the same wedge by another route.
    """
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    holder = _live_holder_named_like_the_floor(tmp_path)
    try:
        _lock(state, pid=holder.pid, age_s=60 * 40)    # far past the 20-min ceiling
        sent = tmp_path / "SENT"
        r = _run_cadence_nudge(home, bindir, screen, session=sent)
        assert r.returncode == 0, r.stdout + r.stderr
        assert sent.exists(), "a holder past the absolute ceiling wedged the floor for ever"
    finally:
        holder.terminate()
        holder.wait(timeout=10)


def test_cadence_nudge_lock_arms_for_an_unowned_lock(tmp_path):
    """No pid file: HELD while young (fail-closed on the mkdir→pid window), reclaimed once stale.

    Both halves matter. Dropping the young arm re-opens the concurrent-send race for a run killed
    between `mkdir` and its pid write; dropping the stale arm makes such a lock (and an old-format
    lock from the previous version) wedge the floor.
    """
    # (a) young, no pid → held, nothing sent.
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    _lock(state, age_s=60)
    sent_a = tmp_path / "SENT_A"
    r = _run_cadence_nudge(home, bindir, screen, session=sent_a)
    assert r.returncode == 0, r.stdout + r.stderr
    assert not sent_a.exists(), "an unowned YOUNG lock was taken over — the mkdir→pid race is open"

    # (b) stale, no pid (and the pid written INSIDE the dir by the intermediate version) → reclaimed.
    seed_b = _seeded_log(600)
    home_b, bindir_b, screen_b, state_b = _cadence_home(
        tmp_path / "b", "the pane shows nothing relevant\n", seed_b)
    _lock(state_b, pid=999999, age_s=3600, pid_inside=True)
    sent_b = tmp_path / "SENT_B"
    r = _run_cadence_nudge(home_b, bindir_b, screen_b, session=sent_b)
    assert r.returncode == 0, r.stdout + r.stderr
    assert sent_b.exists(), "a stale lock was never reclaimed — the floor is wedged"


def test_cadence_nudge_holds_an_unidentifiable_lock_to_the_ceiling_not_the_grace(tmp_path):
    """⛔ A LOCK NOTHING CAN VOUCH FOR MUST OUTLIVE THE SHORT GRACE (#3795 review cycle 3, P2).

    On the arm where the holder cannot be identified (no pid file, an empty/unreadable one, or one
    left inside the dir), the ONLY thing between a second contender and a live sender is the clock —
    and the clock must exceed the ~413 s window it protects. With the short 6-min grace here, a holder
    whose pid write had failed was reclaimed MID-RUN and two receipts landed 4 s apart (measured).

    500 s is the discriminating age: past the 360 s grace, inside the 20-min ceiling.
    """
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    _lock(state, age_s=500)          # no pid at all — unidentifiable
    sent = tmp_path / "SENT"
    r = _run_cadence_nudge(home, bindir, screen, session=sent)
    assert r.returncode == 0, r.stdout + r.stderr
    assert not sent.exists(), (
        "an unidentifiable lock was reclaimed at the short grace — a live sender can be raced inside "
        "its own 413 s window")
    nudges, appended = _new_nudge_lines(state, seed)
    assert not nudges, appended
    assert "lock-skip" in appended and "bound=20m" in appended, appended


def test_cadence_nudge_dead_holder_arm_has_its_own_bound_and_its_own_words(tmp_path):
    """⛔ A DEAD HOLDER IS NOT "UNIDENTIFIABLE" (#3795 review cycle 4, P2).

    The common crash — a nudge SIGKILLed in its ~410 s window — leaves the lock and a pid file naming
    a dead pid. Classifying that with the "names nothing" arm held the floor for the full 20-min
    ceiling (2.7 ticks) AND printed `holder=<pid> … no identifiable holder`, a line that names a
    holder while denying it identifies one. It now has its own bound (10 min, above the window and
    well under the ceiling) and its own words.
    """
    # (a) inside the dead bound: held, and the line says the holder is dead rather than unknown.
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path / "a", "the pane shows nothing relevant\n", seed)
    _lock(state, pid=999999, age_s=300)
    sent = tmp_path / "SENT_A"
    r = _run_cadence_nudge(home, bindir, screen, session=sent)
    assert r.returncode == 0, r.stdout + r.stderr
    assert not sent.exists(), "a 300 s lock was reclaimed before the dead bound"
    _n, appended = _new_nudge_lines(state, seed)
    assert "bound=10m" in appended, appended
    assert "is not running" in appended, appended
    assert "no identifiable holder" not in appended, (
        "the line names a holder and denies identifying one in the same sentence:\n" + appended)

    # (b) past the dead bound: reclaimed, well before the 20-min ceiling.
    seed_b = _seeded_log(600)
    home_b, bindir_b, screen_b, state_b = _cadence_home(
        tmp_path / "b", "the pane shows nothing relevant\n", seed_b)
    _lock(state_b, pid=999999, age_s=700)
    sent_b = tmp_path / "SENT_B"
    r = _run_cadence_nudge(home_b, bindir_b, screen_b, session=sent_b)
    assert r.returncode == 0, r.stdout + r.stderr
    assert sent_b.exists(), "a provably-dead holder was not reclaimed at its own bound"


def test_cadence_nudge_reclaim_is_one_winner_over_a_stale_lock(tmp_path):
    """⛔ THE RECLAIM TOKEN IS THE RECORD, AND CONTENTION OVER A STALE LOCK HAS EXACTLY ONE WINNER.

    This replaced a fixed-name `mkdir` reclaim mutex (#3795 review cycle 6, P1). That mutex was
    measured unsound: `mv`-ing it freed its NAME, so a contender's plain `mkdir` re-claimed it while
    the process that moved it was still inside, and its `elif [ -e … ]` arm then deleted a FRESH
    mutex a live holder still owned. Across 27 sixteen-contender trials 5 logged TWO OR MORE
    `lock-reclaimed` lines — two processes inside a section whose banner called it exclusive — and
    the conversion to a duplicate send is deterministic (`rmdir` always succeeds on the always-empty
    dir, `rm -f "$LOCKPID"` removes the live holder's record, `mkdir` then succeeds for both).

    The token is now `rename(2)` of the record that was judged, so a loser's `mv` fails ENOENT. THE
    DISCRIMINATOR IS THE PRECONDITION: the old burst test started from a CLEAN state, so no
    contender ever entered the reclaim path and the mutex was mutation-invisible (deleting it
    changed nothing). Here eight contenders start over a STALE lock, which is the only configuration
    in which the reclaim token matters.
    """
    from concurrent.futures import ThreadPoolExecutor

    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    _lock(state, pid=999999, age_s=3600)      # stale: past the dead-holder bound, record names a dead pid
    sent = tmp_path / "SENT"

    def once(_i):
        return _run_cadence_nudge(home, bindir, screen, session=sent)

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(once, range(8)))
    for r in results:
        assert r.returncode == 0, r.stdout + r.stderr
    nudges, appended = _new_nudge_lines(state, seed)
    assert len(nudges) == 1, f"{len(nudges)} heartbeats over one stale lock:\n{appended}"
    assert appended.count("lock-reclaimed") == 1, (
        "more than one process reclaimed the same stale lock — the reclaim token is not once-winnable:\n"
        + appended)
    # ...and nothing was left wedged for the next tick.
    assert not (state / "cadence-nudge.lock.pid").exists(), "the winner left a stale pid record behind"
    assert not (state / "cadence-nudge.lock").exists(), "the winner never released the lock"
    assert not list(state.glob("cadence-nudge.lock.pid.doomed.*")), "a doomed record leaked"


def test_cadence_nudge_a_leftover_reclaim_mutex_no_longer_wedges_the_floor(tmp_path):
    """⛔ A `.takeover` LEFT BY A KILLED RUN MUST NOT STOP THE FLOOR (#3795 review cycle 6, P1).

    This is the DETERMINISTIC arm for the reclaim rewrite. The previous fixed-name `mkdir` mutex was
    reclaimed only when `find … -mmin +2` said it was stale, so a mutex left behind by a SIGKILLed run
    held the floor until that clock expired — and if its mtime could not be read at all, for ever, with
    a line that says "or a stale one is not yet expired". The mutex is gone: the reclaim token is a
    `rename(2)` of the record that was judged, so no artifact of a previous run can outlive it.

    The precondition is deliberately the shape that wedged the old code: a FRESH `.takeover` beside a
    STALE lock. Pre-fix the run logs the mutex skip and sends nothing; post-fix the leftover is inert.
    """
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    (state / "cadence-nudge.lock.takeover").mkdir()      # fresh: the old code called this "held"
    _lock(state, pid=999999, age_s=3600)                 # stale, and its record names a dead pid
    sent = tmp_path / "SENT"
    r = _run_cadence_nudge(home, bindir, screen, session=sent)
    assert r.returncode == 0, r.stdout + r.stderr
    assert sent.exists(), (
        "a leftover reclaim mutex wedged the floor — the mutex has no owner left to release it")
    _n, appended = _new_nudge_lines(state, seed)
    assert "lock-reclaimed" in appended, appended
    assert "mutex" not in appended, (
        "the floor still speaks of a reclaim mutex it no longer has:\n" + appended)


def _write_shim(bindir, name, body, real):
    """A `PATH`/`PS_BIN` stand-in that fails ONE read and delegates everything else.

    The body is pasted verbatim, NOT through `textwrap.dedent`: a multi-line body has no common
    indentation with the wrapper lines, so dedent silently left the wrapper indented (harmless in
    bash, but it reads as if the shim were conditional, and a future `set -e`-style body would not be).
    """
    f = bindir / name
    f.write_text("#!/usr/bin/env bash\n" + body + "\nexec " + real + ' "$@"\n', encoding="utf-8")
    f.chmod(f.stat().st_mode | stat.S_IEXEC)
    return f


def test_cadence_nudge_holds_the_lock_when_the_holder_argv_read_fails(tmp_path):
    """⛔ AN EMPTY ARGV IS NOT A DEATH WITNESS (#3795 review cycle 9, P2).

    `_nudge_holder_is_ours` read the holder's argv and returned "not this script" whenever the answer
    was empty — but the caller only reaches it on the `present` arm of `_nudge_holder_state`, i.e. a
    SEPARATE read has already proven the pid is live, and a live process always has an argv. So an
    empty answer here can only be the READ failing, and mapping a failed read onto FOREIGN hands the
    lock a 6-min grace that is SHORTER than this file's own ~413 s critical section — a live holder
    reclaimed MID-SEND, which is the two-receipts-seconds-apart failure the lock exists to prevent.

    DISCRIMINATOR: a live holder whose argv names this script, a 500 s-old lock. Pre-fix the failed read
    made it FOREIGN (6-min bound) and 500 s > 360 s, so the floor RECLAIMED and SENT a second
    heartbeat while the holder was still running. Post-fix it is a holder (20-min ceiling), so the tick
    logs a `bound=20m` skip and sends nothing.
    """
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    holder_dir = tmp_path / "holder"
    holder_dir.mkdir()
    holder = _live_holder_named_like_the_floor(holder_dir)
    try:
        seed = _seeded_log(600)
        home, bindir, screen, state = _cadence_home(
            tmp_path, "the pane shows nothing relevant\n", seed)
        _write_shim(bindir, "ps", 'case "$*" in *"-o args="*) exit 1 ;; esac',
                    shutil.which("ps") or "/bin/ps")
        _lock(state, pid=holder.pid, age_s=500)      # past the 6-min grace, inside the 20-min ceiling
        r = _run_cadence_nudge(home, bindir, screen)
        assert r.returncode == 0, r.stdout + r.stderr
        nudges, appended = _new_nudge_lines(state, seed)
        assert not nudges, (
            "a holder whose argv READ FAILED was reclaimed as foreign and a second heartbeat "
            "left the box:\n" + appended)
        assert "bound=20m" in appended, (
            "a failed argv read was not held to the ceiling:\n" + appended)
    finally:
        holder.kill()
        holder.wait()


def test_cadence_nudge_holds_the_lock_when_the_holder_AGE_cannot_be_read(tmp_path):
    """⛔ `pid_began_after`'s `2` IS NOT ITS `1` (#3795 review cycle 9, P2).

    The library's contract is 0 = began after, 1 = did not, 2 = THE AGE CANNOT BE READ, and it says in
    as many words that folding 2 into 1 manufactures evidence out of a failed read (#1178 C3). The lock
    predicate folded 2 into "not provably ours" instead — FOREIGN, the 6-min grace, shorter than the
    send window. Only an ANSWERED "began after" may demote; a question that could not be put must hold
    the lock to the ceiling, which is what the sibling `date -r` arm already did.

    DISCRIMINATOR: `PS_BIN` fails only `-o etime=` (so `pid_start_epoch` → rc 1 → `pid_began_after` →
    rc 2) while the table read still works. Same 500 s lock as the arm above.
    """
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    holder_dir = tmp_path / "holder"
    holder_dir.mkdir()
    holder = _live_holder_named_like_the_floor(holder_dir)
    try:
        seed = _seeded_log(600)
        home, bindir, screen, state = _cadence_home(
            tmp_path, "the pane shows nothing relevant\n", seed)
        shimbin = tmp_path / "shimbin"
        shimbin.mkdir()
        ps_shim = _write_shim(shimbin, "ps", 'case "$*" in *"-o etime="*) exit 1 ;; esac',
                              shutil.which("ps") or "/bin/ps")
        _lock(state, pid=holder.pid, age_s=500)
        r = _run_cadence_nudge(home, bindir, screen, extra_env={"PS_BIN": ps_shim})
        assert r.returncode == 0, r.stdout + r.stderr
        nudges, appended = _new_nudge_lines(state, seed)
        assert not nudges, (
            "an UNREADABLE holder age was read as foreign and a second heartbeat left the box:\n"
            + appended)
        assert "bound=20m" in appended, (
            "an unreadable age was not held to the ceiling:\n" + appended)
    finally:
        holder.kill()
        holder.wait()


def test_cadence_nudge_never_deletes_a_lock_it_did_not_judge(tmp_path):
    """⛔ THE RECLAIM MUST NOT `rm -rf` THE LIVE NAME (#3795 review cycle 9, P2).

    The record arm renamed the RECORD aside and then unconditionally `rm -rf "$LOCK"` — a directory it
    had not judged. Once the record is gone the lock briefly has no record, so a second contender takes
    the no-record arm, judges the (still old) directory stale, renames it aside, removes it and
    re-creates it; the first process then deleted THAT FRESH directory and took its own. Both send.
    This is the defect round 6 removed from the reclaim MUTEX, one object up.

    THE WINDOW IS INJECTED, NOT MODIFIED INTO THE SCRIPT: an `rm` shim that, on the first `rm` of a
    `…doomed…` name (exactly the instruction the record arm runs between its two steps), creates the
    fresh lock a second contender would have created, then delegates to the real `rm`. Deterministic,
    and the script under test is untouched.

    DISCRIMINATOR: post-fix the directory step renames instead, sees the fresh directory, puts it BACK
    and exits with a `lock-skip`; pre-fix the fresh lock is gone and a second heartbeat is written.
    """
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    seed = _seeded_log(3600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    lock = state / "cadence-nudge.lock"
    lockpid = state / "cadence-nudge.lock.pid"
    hook = tmp_path / "recreate-lock.sh"
    # ⛔ `touch` IS LOAD-BEARING: the lock directory ALREADY EXISTS (it is the stale one being
    # reclaimed), and `mkdir -p` on an existing directory does not move its mtime — so without the
    # touch the "contender" would re-create a directory that still reads as 3600 s old, the freshness
    # verify would pass, and the test would be measuring nothing.
    hook.write_text(
        "#!/usr/bin/env bash\n"
        'rm -rf "$FAKE_LOCK"\n'
        'mkdir -p "$FAKE_LOCK"\n'
        'printf "999997\\n" > "$FAKE_LOCKPID"\n',
        encoding="utf-8")
    hook.chmod(hook.stat().st_mode | stat.S_IEXEC)
    real_rm = shutil.which("rm") or "/bin/rm"
    _write_shim(
        bindir, "rm",
        'case "$*" in *doomed*) if [ ! -e "$FAKE_HOOK_FIRED" ]; then '
        '  : > "$FAKE_HOOK_FIRED"; exec_hook=1; fi ;; esac\n'
        'if [ "${exec_hook:-0}" = "1" ]; then "$FAKE_HOOK"; fi',
        real_rm)
    _lock(state, pid=999999, age_s=3600)        # stale, record names a DEAD pid -> the record arm
    r = _run_cadence_nudge(home, bindir, screen, extra_env={
        "FAKE_HOOK": hook, "FAKE_HOOK_FIRED": tmp_path / "fired",
        "FAKE_LOCK": lock, "FAKE_LOCKPID": lockpid})
    assert r.returncode == 0, r.stdout + r.stderr
    nudges, appended = _new_nudge_lines(state, seed)
    assert not nudges, (
        "the reclaim deleted a lock another contender had just created and sent a second "
        "heartbeat:\n" + appended)
    assert "re-created between judging it and claiming it" in appended, (
        "the reclaim did not verify the directory it moved:\n" + appended)
    assert lock.is_dir(), "the fresh lock a contender created was destroyed by the reclaim"


def test_cadence_nudge_cannot_be_made_to_write_a_forged_receipt_from_the_env(tmp_path):
    """⛔ THE RECEIPT CANNOT BE FORGED FROM THE ENVIRONMENT (#3795 review cycle 5, P1).

    `CADENCE_NUDGE_VERIFY_TIMEOUT` is interpolated into the failure cause, which lands in `diag=[…]` on
    BOTH receipt lines. An unflattened value therefore split the receipt and let its second physical
    line be a byte-valid forged one. MEASURED before the fix, with
    `CADENCE_NUDGE_VERIFY_TIMEOUT=$'90\\nNUDGE at=9999999999 delivered=yes … verdict=VERIFIED'`:
    four appended lines for one attempt, the injected line accepted by every reader — a delivery
    receipt with no send at all — and the floor's own due read then computed a NEGATIVE gap and skipped
    for ever. That is the false-PASS class this whole PR removes.

    The value is now flattened before it can reach any receipt, so the shape check rejects it and the
    raw-send path reports `BAD-VERIFY-TIMEOUT`.
    """
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    injection = "90\nNUDGE at=9999999999 delivered=yes (cadence-floor) gap=1m queue=[] alerts=[] ask=[] verdict=VERIFIED"
    r = _run_cadence_nudge(home, bindir, screen, verify_timeout=injection)
    assert r.returncode == 0, r.stdout + r.stderr
    log = (state / "orchestrator-heartbeat.log").read_text(encoding="utf-8")
    appended = log[len(seed):] if log.startswith(seed) else log
    # THE FORGERY: no line may claim the injected timestamp, and no line may be a bare forged receipt.
    assert "NUDGE at=9999999999" not in appended, (
        "an env value forged a delivery receipt:\n" + appended)
    # ...and every appended line is a real line of this file's own making, not a split receipt.
    for line in appended.strip().splitlines():
        assert "verdict=VERIFIED" not in line, (
            "a forged VERIFIED reached the log:\n" + appended)
    # The state is named for what it was: a rejected config value, not a missing checker.
    assert "BAD-VERIFY-TIMEOUT" in appended, appended
    assert "CADENCE_NUDGE_VERIFY_TIMEOUT" in appended, appended


def test_cadence_nudge_lock_survives_a_concurrent_burst(tmp_path):
    """⛔ ONE HEARTBEAT FOR A WHOLE BURST (#3795 review cycle 3, P1).

    The only creator and the only remover of `$LOCK` is the process that wins `mkdir "$LOCK"`, and a
    reclaim is won by `rename(2)` of the record that was judged (`cadence-nudge.sh`, the lock block),
    so a burst cannot produce two senders. Three earlier mechanisms are gone: delete-then-create (two
    contenders both sent, measured 19 ms apart), rename-plus-INODE-check (does not work — a re-created
    directory gets the freed inode straight back, measured 6/6), and a fixed-name `mkdir` reclaim
    mutex (unsound — `mv` freed its name and it deleted a fresh mutex a live holder owned, measured in
    5 of 27 trials).

    LIMIT, stated rather than implied: this pins the burst invariant on a CLEAN start (N concurrent
    runs -> exactly one heartbeat). The reclaim arm is pinned separately by
    `test_cadence_nudge_reclaim_is_one_winner_over_a_stale_lock`, which is the configuration in which
    the reclaim token actually decides anything — a clean-start burst never enters it.
    """
    from concurrent.futures import ThreadPoolExecutor

    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    sent = tmp_path / "SENT"

    def once(_i):
        return _run_cadence_nudge(home, bindir, screen, session=sent)

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(once, range(8)))
    for r in results:
        assert r.returncode == 0, r.stdout + r.stderr
    nudges, appended = _new_nudge_lines(state, seed)
    assert len(nudges) == 1, (
        f"{len(nudges)} heartbeats left the box for one due window:\n{appended}")
    # ⛔ THIS LINE USED TO ASSERT NOTHING (#3795 review cycle 8, P2). It read
    # `"delivered=yes" in nudges[0] or "delivered=" in nudges[0]` — and the right-hand disjunct is
    # unconditionally true, because `_new_nudge_lines` selects lines that contain `NUDGE at=` and the
    # floor's only producer of that token always writes `delivered=` beside it. So the line read as a
    # pin on the receipt's delivery field while being incapable of failing. This fixture binds no
    # session (`_run_cadence_nudge(..., session=sent)` with no `sid`), so the honest field here is a
    # NON-yes verdict with the verdict named beside it — which is what a burst that raced a lock must
    # not be able to upgrade.
    assert "delivered=yes" not in nudges[0], (
        "a burst over one lock certified a delivery it cannot have verified:\n" + nudges[0])
    assert "verdict=" in nudges[0], (
        "the receipt does not name the verdict it carries:\n" + nudges[0])


def test_cadence_nudge_does_not_report_a_prefix_as_delivered(tmp_path):
    """⛔ THE #1187 FALSE PASS AT THE FLOOR. The pane was never given the payload (the fake cmux
    answers OK and shows nothing, which is the measured shape: `OK` over a one-sentence prefix).
    Pre-fix this wrote `delivered=yes`; the log is the receipt, so it must not."""
    # ⛔ THE CHECKER BRANCH MUST BE THE ONE UNDER TEST (#3795 review cycle 2, P2). Without this skip the
    # test passes VACUOUSLY on a runner with no `/usr/bin/python3`: the NO-USABLE-CHECKER branch also
    # writes `delivered=UNVERIFIED` and `NOT CERTIFIED`, so both assertions would hold while the `case`
    # about is never reached. The raw path's own cause text is unique to it, so asserting it ABSENT is
    # a POSITIVE proof the checker branch ran — not a pin on the verdict token, which a rename would
    # silently turn vacuous again (#3795 review cycle 4, P2).
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    r = _run_cadence_nudge(home, bindir, screen)
    assert r.returncode == 0, r.stdout + r.stderr
    nudges, appended = _new_nudge_lines(state, seed)
    assert nudges, appended
    assert all("delivered=yes" not in line for line in nudges), (
        f"a delivery receipt the send did not earn:\n{appended}")
    assert "delivered=UNVERIFIED" in appended, appended
    assert "verdict=UNVERIFIED" in appended, appended
    assert "payload checker unavailable" not in appended, (
        "the checker branch was never entered, so this test certified nothing:" + appended)
    assert "NOT CERTIFIED" in appended, "an uncertified send must be LOUD, not merely absent"


def test_cadence_nudge_still_reports_delivery_it_can_prove(tmp_path):
    """The fix is not "never say yes": a send the transcript records IS certified."""
    # This arm needs the REAL checker on the interpreter the floor hardcodes.
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(tmp_path, "ok\n", seed)
    sessions = home / ".pi" / "agent" / "sessions" / "proj"
    sessions.mkdir(parents=True)
    session = sessions / f"2026-09-29T12-00-00Z-{sid}.jsonl"
    session.write_text('{"type":"user","content":"an earlier message"}\n', encoding="utf-8")
    r = _run_cadence_nudge(home, bindir, screen, session=session, sid=sid)
    assert r.returncode == 0, r.stdout + r.stderr
    nudges, appended = _new_nudge_lines(state, seed)
    assert nudges, appended
    assert "delivered=yes" in appended, appended
    assert "verdict=VERIFIED" in appended, appended
    assert "NOT CERTIFIED" not in appended, appended


def test_cadence_nudge_never_certifies_from_a_box_whose_resume_scope_rejects_the_flag(tmp_path):
    """⛔ THE CAP ON A FLAG-REJECTING BOX IS THE DELIBERATE CEILING, AND IT IS NOW MEASURED
    (#3795 review cycle 12, P1).

    `cmux_payload.py:244-253` states that `--surface` may not exist on a box's `cmux` at all, and
    that such a box "still caps at `PANE_ONLY`". The objection that stood was that every floor test
    ran against a fake that answers `resume show` IRRESPECTIVE of the flag, so the workspace-only
    fallback was unreachable from the floor's own suite and the receipt it produces had no pin
    anywhere (`rg 'retrying workspace-only' scripts/test_cmux_payload.py` was 0).

    MEASURED, on the box class this repo deploys to cmux Cloud cells: `cmux surface resume show
    --workspace X` exits 2 with `unknown resource scope "surface"` (that CLI's grammar has no
    `surface` scope at all), so the fallback arm is the STEADY STATE there, not an edge case.
    Whether a Mac's cmux accepts `--surface` on the `resume` scope is still unmeasured from a cell;
    the PR records that as a comment rather than implying either answer.

    DISCRIMINATOR: this fixture has everything `VERIFIED` needs — the pane names a session id and
    THAT session's transcript gains the payload bytes during the send (the fake `cmux` appends every
    `send` to it, exactly as `test_cadence_nudge_still_reports_delivery_it_can_prove` sets up) — and
    the only difference between the two tests is that this resume read REFUSES the flag. A
    qualification that trusted an id out of a FAILED read mints `VERIFIED` here, from a transcript
    that may belong to another surface of the same workspace; MEASURED by removing the qualification
    guard, this test REDS on `delivered=yes`.
    """
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(tmp_path, "ok\n", seed)
    sessions = home / ".pi" / "agent" / "sessions" / "proj"
    sessions.mkdir(parents=True)
    session = sessions / f"2026-09-29T12-00-00Z-{sid}.jsonl"
    session.write_text('{"type":"user","content":"an earlier message"}\n', encoding="utf-8")
    before = session.read_text(encoding="utf-8")
    r = _run_cadence_nudge(home, bindir, screen, session=session, sid=sid,
                           extra_env={"FAKE_SURFACE_REJECTED": "1"})
    assert r.returncode == 0, r.stdout + r.stderr
    nudges, appended = _new_nudge_lines(state, seed)
    assert nudges, appended
    # ⛔ THE HEARTBEAT INVARIANT STILL HOLDS: an unqualifiable address costs CERTIFICATION, not the
    # beat. The transcript grew, so a payload really reached the pane on this run.
    assert len(session.read_text(encoding="utf-8")) > len(before), (
        "the floor did not send at all:\n" + appended)
    # ⛔ THE CEILING: an id this process could not QUALIFY never awards a transcript verdict — even
    # though the transcript now HOLDS the tail this send wrote.
    assert "delivered=yes" not in appended, (
        "a delivery receipt was minted from an address the caller could not qualify:\n" + appended)
    assert "verdict=VERIFIED" not in appended, appended
    assert "delivered=UNVERIFIED" in appended, appended
    # ⛔ THE CAUSE IS NAMED — this is what makes the state distinguishable from a stuck composer, and
    # it is the line the operator needs before deciding the beat did not land.
    assert "retrying workspace-only" in appended, (
        "the receipt does not name the surface read as the cause, so NOT CERTIFIED is unexplained:\n"
        + appended)
    # ⛔ POSITIVE PROOF THE CHECKER BRANCH RAN (the raw-send arm also says UNVERIFIED / NOT CERTIFIED).
    assert "payload checker unavailable" not in appended, appended
    assert "NOT CERTIFIED" in appended, appended


def test_cadence_nudge_counts_an_unverified_attempt_so_it_cannot_flood(tmp_path):
    """⛔ THE OTHER SIDE OF THE RECEIPT. If the due-read only counted VERIFIED sends, a run of
    unprovable verifications (the orchestrator mid-turn, its transcript not yet flushed) would read
    as NO nudge for a growing gap and the floor would re-fire on EVERY tick — out of the owner's
    5-9 min band in the over-frequent direction. Every attempt stamps `NUDGE at=`, the verdict sits
    beside it, and a second run inside the band sends nothing."""
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", _seeded_log(600))
    first = _run_cadence_nudge(home, bindir, screen)
    assert first.returncode == 0, first.stdout + first.stderr
    log_path = state / "orchestrator-heartbeat.log"
    after_first = log_path.read_text(encoding="utf-8")
    assert "delivered=UNVERIFIED" in after_first
    second = _run_cadence_nudge(home, bindir, screen)
    assert second.returncode == 0, second.stdout + second.stderr
    assert log_path.read_text(encoding="utf-8") == after_first, (
        "the floor re-fired inside the band after an unverified attempt: it would flood the pane")


def test_cadence_nudge_without_its_checker_still_beats_and_still_refuses_to_certify(tmp_path):
    """The floor's job is that a heartbeat LEAVES even on a broken box. Losing the checker must not
    silence it — but it must not buy a receipt either."""
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    r = _run_cadence_nudge(home, bindir, screen, checker=False)
    assert r.returncode == 0, r.stdout + r.stderr
    nudges, appended = _new_nudge_lines(state, seed)
    assert nudges, appended
    assert all("delivered=yes" not in line for line in nudges), appended
    assert "delivered=UNVERIFIED" in appended, appended
    assert "payload checker unavailable" in appended, appended


# ── the verdict MAPPING in the floor, one arm at a time (#3795 review P2) ──────
#
# The `case` in `cadence-nudge.sh` is where a checker verdict becomes a receipt field. Only the
# VERIFIED and UNVERIFIED arms were pinned, so the two outcome that must NEVER reach `delivered=yes`
# — PANE_ONLY and SUBMIT_FAILED — could drift there with every test still green.

def test_cadence_nudge_reports_pane_only_as_not_submitted_and_names_the_verdict(tmp_path):
    """`PANE_ONLY` is not a delivery verdict (`cmux_payload.py`'s own contract): the tail is on the
    surface, submission is unproven. The receipt must not say `yes` — and must still say WHICH it
    was, since `NOT-SUBMITTED` is shared with `SUBMIT_FAILED`."""
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    r = _run_cadence_nudge(home, bindir, screen, stub_verdict="PANE_ONLY")
    assert r.returncode == 0, r.stdout + r.stderr
    nudges, appended = _new_nudge_lines(state, seed)
    assert nudges, appended
    assert all("delivered=yes" not in line for line in nudges), appended
    assert "delivered=NOT-SUBMITTED" in appended, appended
    assert "verdict=PANE_ONLY" in appended, appended
    assert "NOT CERTIFIED" in appended, appended


def test_cadence_nudge_reports_submit_failed_as_not_submitted(tmp_path):
    """The terminating Enter failed: submission was never attempted. Same receipt value as
    PANE_ONLY, and the verdict on the line is how a reader tells them apart."""
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the payload sits in the composer\n", seed)
    r = _run_cadence_nudge(home, bindir, screen, stub_verdict="SUBMIT_FAILED")
    assert r.returncode == 0, r.stdout + r.stderr
    nudges, appended = _new_nudge_lines(state, seed)
    assert nudges, appended
    assert all("delivered=yes" not in line for line in nudges), appended
    assert "delivered=NOT-SUBMITTED" in appended, appended
    assert "verdict=SUBMIT_FAILED" in appended, appended


def test_cadence_nudge_submits_a_payload_left_in_the_composer_by_a_failed_enter(tmp_path):
    """⛔ `SUBMIT_FAILED` LEAVES THE PAYLOAD TYPED, SO THE FLOOR MUST SUBMIT IT, NOT RE-TYPE IT
    (#3795 review cycle 7, P2).

    The checker types the payload and presses a SEPARATE Enter. When that Enter fails nothing is
    submitted and the text stays in the composer — but the receipt still records the ATTEMPT, so the
    next due tick types the WHOLE heartbeat again on top of it. MEASURED pre-fix on the real floor +
    the real checker against a composer-modelling pane: one submitted message of 4261 bytes with
    `[HEARTBEAT ` in it twice.

    The adopted checker's own contract is the opposite action (`send_verified`: "the remedy is to
    submit in that pane, never to re-send"), so the floor now sends the bare terminating Enter the
    raw-send arm has always used. The receipt says `re-submit-attempted=yes rc=<n>` — the ACT and the
    status the send returned, never a delivery claim — so a retried Enter is distinguishable from one
    that was never retried, and a reader is not invited to read it as "submitted" (#3795 review
    cycles 11 and 13, P2).

    DISCRIMINATOR: with the fix the fake cmux records a second `send` whose payload is the bare `\n`;
    pre-fix it records none. `delivered=` must stay `NOT-SUBMITTED` — the retried Enter is not proof.
    """
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the payload sits in the composer\n", seed)
    sent = tmp_path / "SENT"
    r = _run_cadence_nudge(home, bindir, screen, session=sent, stub_verdict="SUBMIT_FAILED")
    assert r.returncode == 0, r.stdout + r.stderr
    _n, appended = _new_nudge_lines(state, seed)
    assert "verdict=SUBMIT_FAILED" in appended, appended
    assert "delivered=NOT-SUBMITTED" in appended, (
        "a retried Enter was upgraded to a delivery claim it cannot support:\n" + appended)
    assert "re-submit-attempted=yes rc=0" in appended, appended
    sends = sent.read_text(encoding="utf-8").splitlines() if sent.exists() else []
    assert any(line.rstrip().endswith(r" \n") for line in sends), (
        "the payload left in the composer was never submitted, so the next tick duplicates it:\n"
        + "\n".join(sends))


def test_cadence_nudge_reports_a_REFUSED_enter_retry_as_an_attempt_with_its_status(tmp_path):
    """⛔ `re-submit-attempted=no` REPORTED AN ATTEMPT AS AN ABSENCE (#3795 review cycle 13, P2).

    The field used to be split on the retry's exit status (`yes`/`no`), but the retry is INVOKED on
    every `SUBMIT_FAILED` verdict -- so a refused retry printed `no`, which reads as "not attempted":
    a verdict on the act, minted from a status, which is the cycle-11 finding one field over. The
    field now always reports the attempt and the status it returned (`re-submit-attempted=yes rc=<n>`).

    MEASURED pre-fix on this fixture (the fake `cmux` refuses only the bare-`\n` send):
    `delivered=NOT-SUBMITTED … verdict=SUBMIT_FAILED re-submit-attempted=no` -- for a retry that WAS
    made. And the arm was mutation-invisible: deleting the whole `else` branch left the suite green.

    DISCRIMINATOR: this arm reds if the status is dropped (`rc=0` hardcoded) or if the reporting is
    split on the status again; `test_cadence_nudge_submits_a_payload_left_in_the_composer_by_a_failed_enter`
    keeps the accepted-retry side (`rc=0`).
    """
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the payload sits in the composer\n", seed)
    sent = tmp_path / "SENT"
    r = _run_cadence_nudge(home, bindir, screen, session=sent, stub_verdict="SUBMIT_FAILED",
                           extra_env={"FAKE_ENTER_REJECTED": "1"})
    assert r.returncode == 0, r.stdout + r.stderr
    _n, appended = _new_nudge_lines(state, seed)
    assert "verdict=SUBMIT_FAILED" in appended, appended
    assert "delivered=NOT-SUBMITTED" in appended, (
        "a refused Enter retry was upgraded to a delivery claim:\n" + appended)
    assert "re-submit-attempted=yes rc=3" in appended, (
        "a retry that cmux REFUSED was not reported as an attempt, or its status was lost:\n"
        + appended)


def test_cadence_nudge_does_not_re_submit_a_pane_only_verdict(tmp_path):
    """⛔ `PANE_ONLY` IS DELIBERATELY NOT RE-SUBMITTED (#3795 review cycle 7, P2), and this pins the
    asymmetry so a later "why does SUBMIT_FAILED have an extra send?" cleanup cannot silently add
    one.

    `PANE_ONLY` means the tail is on the surface but submission is unproven, so the checker's Enter
    WAS attempted — the composer may already be clear, and a second Enter would submit whatever else
    a human has since typed into that pane. The duplicate exposure `PANE_ONLY` keeps is the
    pre-existing one, stated in the code beside the fix.
    """
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the payload sits in the composer\n", seed)
    sent = tmp_path / "SENT"
    r = _run_cadence_nudge(home, bindir, screen, session=sent, stub_verdict="PANE_ONLY")
    assert r.returncode == 0, r.stdout + r.stderr
    _n, appended = _new_nudge_lines(state, seed)
    assert "verdict=PANE_ONLY" in appended, appended
    assert "re-submit-attempted=" not in appended, (
        "PANE_ONLY pressed Enter a second time; its composer state is unknown, so that can submit "
        "a human's draft:\n" + appended)


@pytest.mark.parametrize("stub_verdict", ["GARBAGE", "VERIFIED\nOK"])
def test_cadence_nudge_never_certifies_an_unrecognised_checker_verdict(tmp_path, stub_verdict):
    """⛔ THE `case` DEFAULT MUST NOT BE `delivered=yes` (#3795 review P2). A checker that prints
    nothing, a token the floor has never heard of, or TWO lines must all land in the loud arm — the
    whole point of the fix is that only a recognised `VERIFIED` buys a receipt."""
    # Without this skip the three arms pass VACUOUSLY on a runner with no `/usr/bin/python3`, because
    # the NO-USABLE-CHECKER branch satisfies both assertions (#3795 review cycle 2, P2).
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    r = _run_cadence_nudge(home, bindir, screen, stub_verdict=stub_verdict)
    assert r.returncode == 0, r.stdout + r.stderr
    nudges, appended = _new_nudge_lines(state, seed)
    assert nudges, appended
    assert all("delivered=yes" not in line for line in nudges), (
        f"an unrecognised verdict ({stub_verdict!r}) bought a delivery receipt:\n{appended}")
    assert "payload checker unavailable" not in appended, (
        "the checker branch was never entered, so this arm certified nothing:" + appended)
    lines = appended.strip().splitlines()
    # ⛔ ONE RECEIPT IS EXACTLY TWO LOG LINES (#3795 review cycle 2, P2). A multi-line verdict used to
    # split the receipt, so the failure line read "NOT CERTIFIED … verdict=VERIFIED" / "OK — the nudge
    # was NOT proven delivered" — a self-contradicting receipt. Measured PRE-flatten at 4 lines for this
    # parametrisation, so the count is what discriminates; `splitlines()` cannot see a stray break.
    assert len(lines) == 2, (
        f"the receipt was split across {len(lines)} log lines instead of 2:\n{appended}")
    # ⛔ AND EACH ARM PINS ITS OWN MAPPED VERDICT POSITIVELY (#3795 review cycle 4, P2). The previous
    # form was `assert A or stub_verdict != "..."`, which is TRUTH-TABLE IDENTICAL to this one — it
    # constrained only the multi-line arm — so two of the three arms asserted nothing about the `case`
    # they exist to pin. `verdict=` must carry exactly what the floor made of the stub's output,
    # flattened, and the raw path cannot produce any of these values.
    expected = " ".join(stub_verdict.split("\n")) or "UNVERIFIED"
    assert f"verdict={expected}" in lines[0], (
        f"the stub printed {stub_verdict!r}; the receipt should carry verdict={expected}:\n{appended}")
    assert "NOT CERTIFIED" in appended, appended


def test_cadence_nudge_writes_no_receipt_when_the_checker_printed_no_verdict(tmp_path):
    """⛔ A PASS THAT NEVER REACHED A VERDICT MUST NOT STAMP `NUDGE at=` (#3795 review P1).

    A checker that exits without printing a verdict never reached one — a pre-send crash, a refusal
    inside argparse, a kill before its `print` — so nothing establishes that a beat was even
    ATTEMPTED. Folding that into `delivered=UNVERIFIED` and then writing the receipt made the log
    claim an attempt that produced no cmux call at all.

    It is not this file's clock alone: `NUDGE at=` is also the TICK's rate-limit clock
    (`orchestrator-heartbeat.sh:475` reads any `NUDGE at=`, `:1053` then exits before its own send).
    An unearned stamp therefore suppressed BOTH beats while the log showed a regular cadence — the
    false-PASS shape this whole change exists to remove, in the field the other clock reads.

    `UNVERIFIED` keeps its documented meaning (a prefix, an unreadable pane, or a refused send — all
    AFTER a send attempt). This third state is `NO-VERDICT` and writes no receipt.
    """
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    r = _run_cadence_nudge(home, bindir, screen, stub_verdict="")
    assert r.returncode == 0, r.stdout + r.stderr
    nudges, appended = _new_nudge_lines(state, seed)
    # THE ASSERTION THAT MATTERS: no `NUDGE at=` line was written, so no clock advanced.
    assert not nudges, (
        "a pass that never reached a verdict stamped a receipt, advancing both the floor's due read "
        f"and the tick's rate-limit clock:\n{appended}")
    assert "delivered=yes" not in appended, appended
    assert "verdict=NO-VERDICT" in appended, (
        "the failure line should name the real state, not borrow `UNVERIFIED`:\n" + appended)
    assert "NOT CERTIFIED" in appended, appended
    # The failure line must NOT be shaped like a receipt: the due read matches
    # `NUDGE at=<digits> delivered=`, so a line without `NUDGE at=` cannot be mistaken for an attempt.
    assert "NUDGE at=" not in appended, appended


# ── the `--surface` read: fall back on a FAILED read, never on an empty one (#3795 review P1) ──
#
# `cmux surface resume show` is called WORKSPACE-ONLY at every other deployed site, and `--surface`
# is recorded as a flag of `send`/`read-screen`, not of the `resume` scope. If this box's cmux
# rejects the flag, the read fails, no session is named, and the floor's best verdict drops to
# PANE_ONLY — i.e. `NOT-SUBMITTED` on every tick on a healthy fleet. A rejected flag must degrade to
# the pre-existing behaviour; a pane that genuinely names no session must NOT, because that retry
# could bind the verification to another surface's transcript.

def test_resolve_session_id_falls_back_to_workspace_only_when_the_flag_is_rejected(P):
    """A non-zero exit from the surface-qualified read is a FAILED read, and the retry must still
    find the session through the workspace-only form every other caller uses."""
    sid = "01a0d648-4097-74b8-8cfd-3df3a071b463"
    seen = []

    def run(argv, timeout=None):
        seen.append(list(argv))
        if "--surface" in argv:
            # What a cmux that does not know the flag does: refuse, print nothing useful.
            return _Proc("", returncode=2)
        return _Proc(sid)

    got = P.resolve_session_id("ws-1", run, sleep=_noop_sleep, surface="surf-9")
    assert got == sid, seen
    assert any("--surface" in argv for argv in seen), "the surface-qualified read was never tried"
    assert any("--surface" not in argv and "resume" in argv for argv in seen), (
        f"no workspace-only retry was made — the flag rejection is unrecoverable:\n{seen}")


def test_cadence_nudge_still_sends_when_the_checker_predates_the_argv(tmp_path):
    """⛔ THE HEARTBEAT INVARIANT, AT THE ONE STATE THIS PR MADE REACHABLE (#3795 review cycle 3, P1).
    `cadence-nudge.sh` is farmed before `lib/cmux_payload.py` (fleet_srcs then lib_srcs), so a box
    whose farm pass stopped between them holds a NEW floor beside a STALE checker — one that exits 2
    on `verify --surface` BEFORE it sends. Presence-only gating took the checker path, nothing left
    the box, and the receipt still said `delivered=UNVERIFIED` — a value this file documents as
    "prefix, unreadable pane, or a refused send", never "nothing was sent". The floor must send, and
    must say why it could not verify."""
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    # A checker that predates the flag: argparse refuses the argv and exits 2 without sending.
    (home / ".pi" / "agent" / "scripts" / "lib" / "cmux_payload.py").write_text(
        "import sys\n"
        "if '--surface' in sys.argv:\n"
        "    sys.stderr.write('error: unrecognized arguments: --surface\\n')\n"
        "    sys.exit(2)\n"
        "sys.exit(0)\n", encoding="utf-8")
    sent = tmp_path / "SENT"
    r = _run_cadence_nudge(home, bindir, screen, session=sent)
    assert r.returncode == 0, r.stdout + r.stderr
    nudges, appended = _new_nudge_lines(state, seed)
    assert nudges, appended
    # THE POINT: a heartbeat left the box anyway.
    assert sent.exists(), (
        "the floor did not send at all — its one invariant is broken:" + appended)
    assert all("delivered=yes" not in line for line in nudges), appended
    assert "delivered=UNVERIFIED" in appended, appended
    # ...and the receipt names the real cause instead of implying a send it never made.
    assert "predates --surface" in appended, appended
    assert "unrecognized arguments" not in appended, (
        "the checker ran anyway and its usage error became the receipt:" + appended)


def test_cadence_nudge_still_sends_when_the_help_READ_fails_but_names_the_flag(tmp_path):
    """⛔ A FAILED `--help` READ IS NOT A USABLE CHECKER, EVEN IF ITS OUTPUT NAMES THE FLAG
    (#3795 review cycle 10, P2).

    The capability gate tested `case "$_help" in *--surface*)` BEFORE consulting `$_hrc`, so a help
    invocation that FAILED but whose merged output happened to contain `--surface` passed the gate —
    "the read failed" read as "the checker is usable". That is the polarity this PR corrects twice
    elsewhere, and it is reachable in the exact state the gate exists for: a farm pass that stopped
    mid-write leaves a copy whose argparse block is truncated, and Python reports the unclosed bracket
    AT THE LINE HOLDING IT, which is where the `--surface` flag is defined.

    MEASURED pre-fix: `send=False` and NO `NUDGE at=` line at all — the floor lost its one invariant
    (a heartbeat leaves even on a broken box) on a box whose checker cannot run.

    DISCRIMINATOR: the flag-bearing FAILING help must take the raw-send path, and the receipt must name
    the SyntaxError rather than a version claim about a checker that never parsed.
    """
    if not os.access(_FLOOR_PY, os.X_OK):
        pytest.skip(f"{_FLOOR_PY} is not executable on this runner")
    seed = _seeded_log(600)
    home, bindir, screen, state = _cadence_home(
        tmp_path, "the pane shows nothing relevant\n", seed)
    # A truncated copy: it does NOT parse, and its failing help text still names the flag.
    (home / ".pi" / "agent" / "scripts" / "lib" / "cmux_payload.py").write_text(
        "import sys\n"
        "if '--help' in sys.argv:\n"
        "    sys.stderr.write('  File x, line 9\\n    p.add_argument(\"--surface\", default=None)'\n"
        "                     'SyntaxError: ( was never closed\\n')\n"
        "    sys.exit(1)\n"
        "sys.exit(0)\n", encoding="utf-8")
    sent = tmp_path / "SENT"
    r = _run_cadence_nudge(home, bindir, screen, session=sent)
    assert r.returncode == 0, r.stdout + r.stderr
    nudges, appended = _new_nudge_lines(state, seed)
    assert sent.exists(), (
        "a checker whose help READ FAILED but named the flag suppressed the send — the floor's one "
        "invariant is broken:\n" + appended)
    assert nudges, appended
    assert all("delivered=yes" not in line for line in nudges), appended
    assert "verify --help failed" in appended, (
        "a failed help read was not reported as a failure:\n" + appended)
    assert "predates --surface" not in appended, (
        "a checker that never parsed was described as merely OLD:\n" + appended)


def test_resolve_session_id_does_not_fall_back_when_the_read_succeeded_but_named_no_session(P):
    """⛔ AN EMPTY ANSWER IS AN ANSWER (#3795 review P1). `surface resume show` exits 0 with empty
    stdout for a pane that names no session. Falling back there would let the workspace' OTHER
    surface supply the id, and this send's tail would then be verified against a transcript it was
    never written to — the false PASS the whole helper exists to prevent."""
    seen = []

    def run(argv, timeout=None):
        seen.append(list(argv))
        if "--surface" in argv:
            return _Proc("", returncode=0)          # read fine, names no session
        return _Proc("01a0d648-4097-74b8-8cfd-3df3a071b463")

    got = P.resolve_session_id("ws-1", run, sleep=_noop_sleep, surface="surf-9")
    assert got is None, got
    assert all("--surface" in argv for argv in seen), (
        f"an EMPTY (but successful) read was treated as a failed one:\n{seen}")
