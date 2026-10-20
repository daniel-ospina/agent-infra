#!/usr/bin/env python3
"""Tests for the cmux payload-integrity helper (#1187).

The defect these pin is a FALSE PASS, so the tests are written around the two
speech acts the helper must keep distinct:

  * `VERIFIED`  — "the payload's tail is on the recipient's surface"; and
  * `UNVERIFIED`— "I could not see the tail", which covers a truncated prefix,
                   an unreadable surface, and an empty payload alike.

Collapsing the second into the first is the measured regression: `cmux send`
returned `OK` while the recipient received the first sentence of a 1,962-byte
message (issue #1187).
"""
from __future__ import annotations

import importlib.util
import os
import stat
import subprocess
import textwrap

import pytest

_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "cmux_payload.py")
_ORCH_SEND = os.path.join(os.path.dirname(os.path.abspath(__file__)), "orch-send.sh")

LONG = (
    "Read the brief at /tmp/1187-brief.md and execute it end to end. "
    "Do not stop to ask for permission, and do not merge. "
    "TAIL-SENTINEL-9f3c: the last instruction is the one that must arrive."
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

def test_full_payload_on_screen_is_verified(P):
    assert P.screen_has_payload(f"some earlier output\n{LONG}\n", LONG) is True


def test_prefix_truncation_is_unverified(P):
    # Exactly the measured failure: the head arrived, the tail did not.
    prefix = LONG[: len(LONG) // 3]
    assert P.screen_has_payload(prefix, LONG) is False


def test_tail_split_by_a_line_wrap_is_still_verified(P):
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
            if [ -n "${FAKE_SESSION_FILE:-}" ]; then printf '%s\\n' "$args" >>"$FAKE_SESSION_FILE"; fi
            echo "OK surface:1 workspace:1" ;;
          *"workspace list"*) echo '{"workspaces":[]}' ;;
          *) echo "" ;;
        esac
        '''))
    cmux.chmod(cmux.stat().st_mode | stat.S_IEXEC)
    return bindir, screen


def _run_orch_send(bindir, screen, message, home=None, session=None, sid=None, script=None):
    env = dict(os.environ)
    env["PATH"] = f"{bindir}{os.pathsep}{env['PATH']}"
    env["FAKE_SCREEN_FILE"] = str(screen)
    env["ORCH_SEND_VERIFY_TIMEOUT"] = "0"
    if home:
        env["HOME"] = str(home)
    if session:
        env["FAKE_SESSION_FILE"] = str(session)
    if sid:
        env["FAKE_SESSION_SID"] = sid
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
    missing a sibling is reproduced without touching this checkout."""
    root = tmp_path / "farmed"
    (root / "scripts").mkdir(parents=True)
    script = root / "scripts" / "orch-send.sh"
    script.write_text(open(_ORCH_SEND, encoding="utf8").read())
    if checker_body is not None:
        (root / "scripts" / "lib").mkdir()
        (root / "scripts" / "lib" / "cmux_payload.py").write_text(checker_body)
    return script


def test_orch_send_refuses_when_the_checker_is_missing(tmp_path):
    """⛔ P2 (#1881 review): the helper OWNS the send, so a farmed copy WITHOUT its checker
    sibling means NOTHING was dispatched. The pre-fix code fell into the `UNVERIFIED` arm, which
    begins "SENT BUT NOT VERIFIED" — false — and prescribes a re-send that would fail identically
    forever. The refusal must say what is missing, and the send must not happen at all."""
    script = _farmed_copy(tmp_path)                     # no lib/cmux_payload.py
    sent_log = tmp_path / "sent.log"
    bindir, screen = _fake_cmux_path(tmp_path, "Working... (turn started)\n")
    r = _run_orch_send(bindir, screen, LONG, script=script, session=sent_log)
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
