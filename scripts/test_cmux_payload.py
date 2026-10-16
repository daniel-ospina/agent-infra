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

def test_send_verified_when_the_tail_is_on_the_pane(P):
    run = _fake_cmux(f"working...\n{LONG}\n")
    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.VERIFIED
    # the payload was actually sent, then the terminating Enter
    assert run.calls["send"] == 2


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
    (sessions / f"2026-09-29T12-00-00Z-{sid}.jsonl").write_text(LONG + "\n")
    monkeypatch.setenv("HOME", str(home))

    run = _fake_cmux("pane scrolled past the message", surface_out=f"{sid}\n")
    verdict, _ = P.send_verified("ws-1", LONG, run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.VERIFIED


def test_empty_payload_never_reports_verified(P):
    run = _fake_cmux("anything at all")
    verdict, _ = P.send_verified("ws-1", "", run=run, sleep=_noop_sleep, timeout_s=0)
    assert verdict == P.UNVERIFIED


# ── end-to-end: the orchestrator send path (scripts/orch-send.sh) ──────────────
#
# The helper is only the fix if the path that actually dispatches lanes USES it.
# These drive the real script with a PATH-shimmed `cmux`, so the wiring (send +
# verify + exit code) is pinned, not just the module.

def _fake_cmux_path(tmp_path, screen_text):
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
          *read-screen*"--lines 200"*) cat "${FAKE_SCREEN_FILE:-/dev/null}" ;;
          *read-screen*"--lines 10"*) cat "${FAKE_SCREEN_FILE:-/dev/null}" ;;
          *read-screen*) echo "/Users/test/Documents/GitHub/agent-infra" ;;
          *send*) echo "OK surface:1 workspace:1" ;;
          *"workspace list"*) echo '{"workspaces":[]}' ;;
          *) echo "" ;;
        esac
        '''))
    cmux.chmod(cmux.stat().st_mode | stat.S_IEXEC)
    return bindir, screen


def _run_orch_send(bindir, screen, message):
    env = dict(os.environ)
    env["PATH"] = f"{bindir}{os.pathsep}{env['PATH']}"
    env["FAKE_SCREEN_FILE"] = str(screen)
    env["ORCH_SEND_VERIFY_TIMEOUT"] = "0"
    return subprocess.run(["bash", _ORCH_SEND, "ws-1", "TEST", message],
                          capture_output=True, text=True, env=env, timeout=60)


def test_orch_send_reports_consumed_only_when_the_tail_is_verified(tmp_path):
    # Same started-turn line as the prefix test: the difference between the two cases must
    # be the TAIL, never the turn signal (which is present in both).
    bindir, screen = _fake_cmux_path(tmp_path, f"Working... (turn started)\n{LONG}\n")
    r = _run_orch_send(bindir, screen, LONG)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "CONSUMED" in r.stdout
    assert "NOT VERIFIED" not in r.stdout


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
