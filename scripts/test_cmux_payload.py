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
import stat
import subprocess
import textwrap

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
