#!/usr/bin/env python3
"""test_lane_relaunch.py — the guard rails around the non-destructive lane relaunch (#942).

This file is a guard rail, not documentation. `scripts/lane-relaunch.py` types a command into a
LIVE pane, so every test here exists to prove a way it could act on something it must not:

  R1 a LIVE pi in the pane            -> never typed into (prompt guard AND session-record guard)
  R1' the session record unreadable   -> refuses; an unread read is not a licence to type
  R2 the recorded session has no file -> refuses; `--new` is the explicit way to say "fresh"
  R3 no cwd / no `pi` binary          -> refuses; a launch line that cannot work is the failure
  R4 any destructive verb, ever       -> no argv on ANY path contains one (#942's own defect)
  R5 a send with no transcript advance -> UNCONFIRMED, never OK (the outcome-canary proof rule)
  R6 the beat names a remedy that does not exist -> the defect that produced this issue

Run: python3 -m pytest scripts/test_lane_relaunch.py -q
"""
import ast
import importlib.util
import json
import os
import re
import sys
import tempfile

import pytest

_HERE = os.path.dirname(os.path.abspath(__file__))
_MINE = os.path.join(_HERE, "lane-relaunch.py")
_REPO = os.path.dirname(_HERE)

# A REAL transcript file, so a test that is not about the transcript guard is not stopped by it.
_T = os.path.join(tempfile.mkdtemp(prefix="lane-relaunch-t-"), "s-1.jsonl")
with open(_T, "w") as _fh:
    _fh.write("{}\n")

# ⛔ THE LAUNCH CWD MUST NOT DEPEND ON TEST ORDER (review round 5, P2). Several rows pass
# `cwd="/tmp/lane"` and only passed because `_run` happens to create it as a side effect — so
# `pytest -k <one of them>` failed on a clean box. The directory is part of the FIXTURE, created at
# import time, so every row is self-sufficient in isolation as well as in the full run.
LANE_CWD = "/tmp/lane"
os.makedirs(LANE_CWD, exist_ok=True)


@pytest.fixture(scope="module")
def R():
    spec = importlib.util.spec_from_file_location("lane_relaunch_under_test", _MINE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ── fakes ---------------------------------------------------------------------------------------
class FakeLS:
    """Stands in for lane-status.py. Delegates NOTHING on purpose: this file pins the tool's OWN
    guard order, and a fake that re-implemented the shared resolution would be testing itself."""

    def __init__(self, screen="dev@box repo % ", working=False, session="s-1", transcript=_T,
                 cwd="/tmp/lane", session_dir=None):
        self._screen = screen
        self._working = working
        self._session = session
        self._transcript = transcript
        self._cwd = cwd
        # ⛔ A PRIVATE ROOT (review round 6, note): `SD` is the PARENT of the session dir, so pointing
        # it at /tmp made every row glob the real /tmp — and `stray_new_sessions == 1` then raced any
        # other process writing /tmp/<dir>/*.jsonl between the two globs.
        self._root = session_dir or tempfile.mkdtemp(prefix="lane-sessions-")
        self._session_dir = os.path.join(self._root, "lane")

    # ── the primitives the FRESH arm's baseline uses. ⛔ `parent_cwd`/`_same_dir` mirror the REAL
    # semantics (read the transcript's own first record; compare realpaths) — they are not what is
    # under test. `mangled()` is deliberately NOT provided: the tool must never derive a directory
    # from it (review round 5, P1: `lane-status.mangled` turns `.` into `-`, pi keeps the dot, and
    # every fleet lane lives in a dotted path).
    @property
    def SD(self):
        return os.path.dirname(self._session_dir)

    def parent_cwd(self, path):
        try:
            with open(path, errors="ignore") as fh:
                return json.loads(fh.readline()).get("cwd")
        except Exception:
            return None

    @staticmethod
    def _same_dir(a, b):
        """The REAL `lane-status._same_dir` semantics — tolerant of ancestor/descendant. The tool must
        NOT use it for identity (review round 6, P2), and a fake that made it strict could not detect
        that mistake."""
        if not a or not b:
            return False
        ra, rb = os.path.realpath(a), os.path.realpath(b)
        return ra == rb or ra.startswith(rb + os.sep) or rb.startswith(ra + os.sep)

    def new_session(self, name, cwd="/tmp/lane"):
        """Write a transcript where PI would write it, with the cwd in its first record."""
        d = self._session_dir
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, name)
        with open(p, "w") as fh:
            fh.write(json.dumps({"type": "session", "id": name, "cwd": cwd}) + "\n")
        return p

    def read_screen(self, ws, lines=14):
        if isinstance(self._screen, list):
            return self._screen.pop(0) if len(self._screen) > 1 else self._screen[0]
        return self._screen

    def ui_working(self, ws):
        return self._working

    def resolve_session(self, ws):
        return self._session

    def session_file(self, sid):
        return self._transcript

    def workspace_cwds(self):
        return {str(self._ws_upper()).upper(): self._cwd} if self._cwd else {}

    def _ws_upper(self):
        return "WS-1"


class FakeCmux:
    """A `cmux` with NO daemon: `sessions list` answers from `record`, `send` records its argv."""

    def __init__(self, record=False, record_rc=0, record_out=None, send_rc=0, on_send=None):
        self.calls = []
        self.record = record
        self.record_rc = record_rc
        self.record_out = record_out
        self.send_rc = send_rc
        self.on_send = on_send

    def __call__(self, argv, timeout=60):
        self.calls.append(list(argv))
        if argv[:3] == ["cmux", "sessions", "list"]:
            return self._sessions()
        if argv[:2] == ["cmux", "send"]:
            if self.on_send:
                self.on_send()
            return self.send_rc, "", ("" if self.send_rc == 0 else "send failed")
        return 0, "", ""

    def _sessions(self):
        if self.record_rc != 0:
            return self.record_rc, "", "boom"
        if self.record_out is not None:
            return 0, self.record_out, ""
        if self.record:
            return (0, "id=x pid=42 pid_exists=yes workspace=WS-1 title=t\n", "")
        # The ordinary case: a readable roster in which OUR workspace has no live pi.
        return (0, "id=y pid=4 pid_exists=no workspace=WS-9 title=other\n", "")

    def sent(self):
        return [c for c in self.calls if c[:2] == ["cmux", "send"]]


def _clock(start=1000.0, step=10.0):
    box = {"t": start - step}

    def now():
        box["t"] += step
        return box["t"]
    return now


def _run(R, ls, cmux, **kw):
    kw.setdefault("pi", sys.executable)
    kw.setdefault("cwd", "/tmp/lane")
    kw.setdefault("wait", 45)
    os.makedirs("/tmp/lane", exist_ok=True)
    return R.relaunch("ws-1", ls=ls, runner=cmux, sleep=lambda _s: None, clock=_clock(), **kw)


# ── R1: never type into a live session ----------------------------------------------------------
def test_refuses_when_no_shell_prompt(R):
    """A pi footer as the last line is NOT a shell prompt. The guard is the refusal, so deleting it
    must turn this red: with the guard removed the tool sends into a live model."""
    cmux = FakeCmux()
    obs = _run(R, FakeLS(screen="  ⏵⏵ accept edits on (shift+tab to cycle)  /800k  -flash • high"),
               cmux)
    assert obs["refused"] is True
    assert "shell prompt" in obs["reason"]
    assert cmux.sent() == [], cmux.sent()


def test_refuses_a_pi_input_line(R):
    """`> ` is pi's INPUT line. It must not be accepted as a shell prompt (the reason `>` is not in
    PROMPT_TAILS) — accepting it types the launch line into a running session."""
    cmux = FakeCmux()
    obs = _run(R, FakeLS(screen="working…\n>"), cmux)
    assert obs["refused"] is True, obs
    assert cmux.sent() == []


def test_refuses_when_live_pi_record_bound(R):
    """The orthogonal half: the pane read can be fooled, the session record cannot be faked by
    output text. A live record means the lane is NOT dead."""
    cmux = FakeCmux(record=True,
                    record_out="id=x pid=42 pid_exists=yes workspace=WS-1 title=t\n")
    obs = _run(R, FakeLS(), cmux)
    assert obs["refused"] is True
    assert "LIVE pi session record" in obs["reason"]
    assert cmux.sent() == []


def test_refuses_when_session_record_unreadable(R):
    """An unread roster is UNKNOWN, never 'no live pi' — the fleet's own rule."""
    cmux = FakeCmux(record_rc=1)
    obs = _run(R, FakeLS(), cmux)
    assert obs["refused"] is True
    assert "unreadable" in obs["reason"]
    assert cmux.sent() == []


def test_refuses_on_empty_session_record(R):
    """rc=0 with EMPTY stdout is not an answer either — but this is the EMPTY case, not the
    renamed-key case; `test_refuses_when_roster_rows_are_unparseable` pins that one (review round 2:
    this test's docstring used to claim the renamed-key coverage it did not have)."""
    cmux = FakeCmux(record_out="")
    obs = _run(R, FakeLS(), cmux)
    assert obs["refused"] is True
    assert cmux.sent() == []


def test_refuses_when_roster_rows_are_unparseable(R):
    """A roster we READ but cannot parse is UNKNOWN, not "no live pi" (review round 2, P1).

    A cmux bump renames `pid_exists`/`workspace`; every row stops matching and the old code fell
    through to False — which the caller quotes as the licence to type into the pane. The class this
    closes: "a roster we could not read must never be quoted as no live pi".
    """
    for roster in (
        "id=x pid=42 pid_exists=true workspace=WS-1\n",   # value changed: `true`, not `yes`
        "session=WS-1 state=live pid=42\n",              # keys renamed entirely
        "workspace WS-1 running\n",                        # not key=value at all
        # ⛔ AN EMPTY `workspace=` VALUE MUST NOT RAISE (review round 5, P2). `.split()[0]` on an
        # empty value raised IndexError, which escaped `relaunch()` and was reported as ERROR
        # (exit 1) — a crash where this function's contract says UNKNOWN. The fleet's own parser of
        # the same roster guards this shape (`orchestrator-heartbeat.sh:639-645`).
        "id=x pid=1 pid_exists=no workspace=\n",
        "id=x pid=1 pid_exists=no workspace=,\n",
    ):
        cmux = FakeCmux(record_out=roster)
        obs = _run(R, FakeLS(), cmux)
        assert obs["refused"] is True, (roster, obs)
        assert "unreadable" in obs["reason"], (roster, obs["reason"])
        assert cmux.sent() == [], (roster, cmux.sent())


def test_refuses_when_our_own_row_is_unreadable(R):
    """The precise hole: OTHER rows parse, so "the roster is fine" is true — but the row that names
    OUR workspace does not, so "our workspace is not live" is unproven. Absence is only an answer
    when we could read the rows we needed."""
    cmux = FakeCmux(record_out="id=y pid=4 pid_exists=no workspace=WS-9 title=other\n"
                               "session=WS-1 state=live pid=42\n")
    obs = _run(R, FakeLS(), cmux)
    assert obs["refused"] is True, obs
    assert "unreadable" in obs["reason"], obs["reason"]
    assert cmux.sent() == []


def test_our_own_pid_exists_no_row_is_a_real_no(R):
    """Our own row, readable, `pid_exists=no` — the ordinary DEAD lane. This must NOT be treated as
    unreadable: an UNKNOWN here would refuse every legitimate relaunch, and it is the value the
    heartbeat's own DEAD definition reads."""
    cmux = FakeCmux(record_out="id=y pid=4 pid_exists=no workspace=WS-9 title=other\n"
                               "id=z pid=0 pid_exists=no workspace=WS-1 title=ours\n")
    obs = _run(R, FakeLS(transcript=_T), cmux)
    assert obs["refused"] is False, obs
    assert cmux.sent(), "a readable pid_exists=no row for our workspace is a DEAD lane, not a refusal"


def test_a_shaped_roster_without_our_workspace_is_a_real_no(R):
    """The negative control: a readable roster in the expected shape that simply does not name our
    workspace IS evidence of absence — otherwise the guard above would refuse every relaunch."""
    cmux = FakeCmux(record_out="id=y pid=4 pid_exists=no workspace=WS-9 title=other\n")
    obs = _run(R, FakeLS(transcript=_T), cmux)
    assert obs["refused"] is False, obs
    assert cmux.sent(), "a readable roster without our workspace must not block the relaunch"


def test_refuses_when_pane_unreadable(R):
    cmux = FakeCmux()
    obs = _run(R, FakeLS(screen="   \n  "), cmux)
    assert obs["refused"] is True
    # ⛔ THE REASON, NOT JUST THE REFUSAL (review round-7 residual 7): a whitespace-only read is
    # also not a shell prompt, so the prompt guard below refused it too and this row stayed green
    # with its OWN guard deleted — a fail-closed masking, not a pin.
    assert "UNREADABLE" in obs["reason"], obs
    assert cmux.sent() == []


def test_refuses_when_mid_turn(R):
    cmux = FakeCmux()
    obs = _run(R, FakeLS(working=True), cmux)
    assert obs["refused"] is True
    assert "Working" in obs["reason"]
    assert cmux.sent() == []


# ── R2: the stale resume target ----------------------------------------------------------------
def test_refuses_when_transcript_missing(R):
    """#942's aggravating factor 2: the stored resume target can name a session file that is gone.
    Resuming would start an EMPTY session that looks like a restore."""
    cmux = FakeCmux()
    obs = _run(R, FakeLS(session="dead-id", transcript=None), cmux)
    assert obs["refused"] is True
    assert "NO transcript" in obs["reason"]
    assert "--new" in obs["reason"]
    assert cmux.sent() == []


# ── R3: a launch line that cannot work ---------------------------------------------------------
def test_refuses_when_cwd_unresolvable(R):
    cmux = FakeCmux()
    obs = R.relaunch("ws-1", ls=FakeLS(cwd=None), runner=cmux, pi=sys.executable, cwd=None,
                     sleep=lambda _s: None, clock=_clock())
    assert obs["refused"] is True
    assert "cwd unresolved" in obs["reason"]
    assert cmux.sent() == []


def test_refuses_when_pi_missing(R, tmp_path):
    cmux = FakeCmux()
    obs = R.relaunch("ws-1", ls=FakeLS(), runner=cmux, pi=str(tmp_path / "nope"),
                     cwd=str(tmp_path), sleep=lambda _s: None, clock=_clock())
    assert obs["refused"] is True
    assert "not found" in obs["reason"]
    assert cmux.sent() == []


def test_refuses_when_pi_is_not_an_executable_file(R, tmp_path):
    """`os.path.exists` accepted a 0644 file and a DIRECTORY (review round 3, P2) and then sent a
    launch line that provably cannot run — the exact failure this guard exists for. Same standard
    the R6 test holds the prescribed remedy to."""
    plain = tmp_path / "pi-plain"
    plain.write_text("#!/bin/sh\n")
    plain.chmod(0o644)
    adir = tmp_path / "pi-dir"
    adir.mkdir()
    for pi in (str(plain), str(adir)):
        cmux = FakeCmux()
        obs = R.relaunch("ws-1", ls=FakeLS(), runner=cmux, pi=pi,
                         cwd=str(tmp_path), sleep=lambda _s: None, clock=_clock())
        assert obs["refused"] is True, (pi, obs)
        assert "executable file" in obs["reason"], (pi, obs["reason"])
        assert cmux.sent() == [], (pi, cmux.sent())


# ── the happy path, and R5 ---------------------------------------------------------------------
def _transcript(tmp_path):
    p = tmp_path / "s-1.jsonl"
    p.write_text("{}\n")
    return str(p)


def test_confirmed_only_when_the_transcript_advances(R, tmp_path):
    path = _transcript(tmp_path)

    def advance():
        with open(path, "a") as fh:
            fh.write('{"turn":"started"}\n')
    cmux = FakeCmux(on_send=advance)
    obs = _run(R, FakeLS(transcript=path), cmux)
    assert obs["confirmed"] is True, obs
    assert "ADVANCED" in obs["reason"]
    sent = cmux.sent()
    assert len(sent) == 1
    line = sent[0][-1]
    assert line.startswith("cd /tmp/lane && %s --session s-1" % sys.executable)
    assert line.endswith("\n"), "the trailing newline is part of the payload (#941: without it the text never submits)"


def test_send_without_advance_is_unconfirmed(R, tmp_path):
    """R5: an exit-0 send proves bytes were written, not that a lane came back."""
    path = _transcript(tmp_path)
    cmux = FakeCmux()
    obs = _run(R, FakeLS(transcript=path), cmux)
    assert obs["confirmed"] is False
    assert obs["refused"] is False
    assert obs["sent"] is True
    assert "UNCONFIRMED" in obs["reason"] or "no transcript advance" in obs["reason"]


def test_send_rc_nonzero_is_unconfirmed_and_says_the_argv(R, tmp_path):
    path = _transcript(tmp_path)
    cmux = FakeCmux(send_rc=1)
    obs = _run(R, FakeLS(transcript=path), cmux)
    assert obs["confirmed"] is False
    assert obs["sent"] is True
    assert "cmux send rc=" in obs["reason"]


def test_new_starts_a_fresh_session_and_needs_no_transcript(R, tmp_path):
    cmux = FakeCmux()
    obs = R.relaunch("ws-1", ls=FakeLS(transcript=None), runner=cmux, pi=sys.executable,
                     cwd="/tmp/lane", new=True, sleep=lambda _s: None, clock=_clock())
    assert obs["refused"] is False, obs
    line = cmux.sent()[0][-1]
    assert "--session" not in line, line
    assert obs["action"] == "relaunch-fresh"


def test_new_confirms_when_a_transcript_APPEARS(R):
    """Proof (i): a transcript that was NOT there before the send and whose OWN first record names
    this cwd. The fixture writes the cwd into the record — it does not implement a naming rule, so
    the row can actually disagree with the implementation (review round 5, P1)."""
    ls = FakeLS(transcript=None, session=None)
    cmux = FakeCmux(on_send=lambda: ls.new_session("2026-new.jsonl"))
    obs = R.relaunch("ws-1", ls=ls, runner=cmux, pi=sys.executable, cwd="/tmp/lane", new=True,
                     sleep=lambda _s: None, clock=_clock())
    assert obs["confirmed"] is True, obs
    assert "appeared" in obs["reason"], obs


def test_new_does_not_count_a_transcript_from_an_ANCESTOR_cwd(R):
    """The strictness that matters: a pi session that begins in an ANCESTOR of the lane's cwd (the repo
    root, `$HOME`, the worktrees dir) is a different lane's business. `_same_dir` would call this a
    match; identity does not."""
    ls = FakeLS(transcript=None, session=None)
    cmux = FakeCmux(on_send=lambda: ls.new_session("root.jsonl", cwd="/tmp"))
    obs = R.relaunch("ws-1", ls=ls, runner=cmux, pi=sys.executable, cwd="/tmp/lane", new=True,
                     sleep=lambda _s: None, clock=_clock())
    # ⛔ `refused is False` (review round-7 residual 2): these rows call `relaunch` directly and
    # `/tmp/lane` exists only as a side effect of `_run`, so in isolation their `confirmed is False`
    # could be the CWD GUARD's answer rather than the cwd filter's. Pin the arm they name.
    assert obs["refused"] is False, obs
    assert obs["confirmed"] is False, "an ancestor cwd confirmed the relaunch: %r" % (obs,)


def test_new_does_not_count_a_transcript_from_a_DESCENDANT_cwd(R):
    """...and the mirror: a session started in a SUBDIRECTORY of the lane's cwd is not this relaunch."""
    ls = FakeLS(transcript=None, session=None)
    cmux = FakeCmux(on_send=lambda: ls.new_session("sub.jsonl", cwd="/tmp/lane/scripts"))
    obs = R.relaunch("ws-1", ls=ls, runner=cmux, pi=sys.executable, cwd="/tmp/lane", new=True,
                     sleep=lambda _s: None, clock=_clock())
    assert obs["refused"] is False, obs
    assert obs["confirmed"] is False, obs


def test_new_does_not_count_a_transcript_from_ANOTHER_cwd(R):
    """The cwd filter is the point: another lane starting a session must not confirm THIS relaunch."""
    ls = FakeLS(transcript=None, session=None)
    cmux = FakeCmux(on_send=lambda: ls.new_session("other.jsonl", cwd="/tmp/somewhere-else"))
    obs = R.relaunch("ws-1", ls=ls, runner=cmux, pi=sys.executable, cwd="/tmp/lane", new=True,
                     sleep=lambda _s: None, clock=_clock())
    assert obs["confirmed"] is False, obs
    assert obs.get("stray_new_sessions") == 1, obs


def test_new_is_not_blocked_when_the_RESUME_TARGET_is_unresolvable(R):
    """⛔ `--new` IS THE REMEDY FOR A BROKEN RESUME TARGET, so it must not be refused BECAUSE the
    resume target is broken (review round 3, P2). It needs no session id at all."""
    class Raising(FakeLS):
        def resolve_session(self, ws):
            raise RuntimeError("resolve blew up")

    cmux = FakeCmux(on_send=lambda: None)
    obs = R.relaunch("ws-1", ls=Raising(transcript=None, session=None), runner=cmux,
                     pi=sys.executable, cwd="/tmp/lane", new=True,
                     sleep=lambda _s: None, clock=_clock())
    assert obs["refused"] is False, obs
    assert cmux.sent(), "--new must reach the send even when the resume target cannot be resolved"


def test_new_never_reports_the_STALE_id_it_was_asked_to_abandon(R):
    """A confirmed `--new` must never report the pre-launch id it was told to ABANDON.

    ⛔ THE RESOLVER MUST BE LEFT ALONE HERE (review round 4, P1). The first version of this test
    overrode `resolve_session` to return None, which is the one shape that cannot fail — and the
    REAL resolver falls back to the RECORDED id in `lane-sessions.json` whenever the pane has no cmux
    resume record (`lane-status.py:957-961`), which is exactly the state a manual relaunch leaves.
    So the id it returns after `--new` can equal the stale one, and only a test that lets the fake
    resolve to the stale id can see it. Both confirm arms are exercised.
    """
    for label, make in (
        # appearance arm: a new transcript for this cwd shows up
        ("appearance", lambda ls: FakeCmux(on_send=lambda: ls.new_session("new.jsonl"))),
        # prompt-transition arm: the pane leaves the shell prompt, no transcript needed
        ("prompt", lambda ls: FakeCmux()),
    ):
        ls = FakeLS(session="STALE-OLD", transcript=None,
                    screen=["dev@box repo % ", "pi tui line", "  /800k  -flash • high"])
        ls.resolve_session = lambda ws: "STALE-OLD"   # the REAL fallback: the recorded id
        cmux = make(ls)
        obs = R.relaunch("ws-1", ls=ls, runner=cmux, pi=sys.executable, cwd="/tmp/lane", new=True,
                         sleep=lambda _s: None, clock=_clock())
        assert obs["confirmed"] is True, (label, obs)
        assert obs["sid"] != "STALE-OLD", (
            "%s arm: a fresh relaunch was reported as bound to the session --new was asked to "
            "abandon: %r" % (label, obs))


def test_new_reports_a_genuinely_new_id(R):
    """The positive control: when the resolver names a DIFFERENT session after the send, report it —
    otherwise the fix would be "never report a sid", which is a different (and useless) answer.

    The resolver is STATEFUL on purpose: the real one returns the recorded (pre-launch) id before the
    relaunch and the new session's id once the pane carries a resume record. A constant fake cannot
    tell "new" from "unchanged", which is the whole distinction under test.
    """
    ls = FakeLS(session="STALE-OLD", transcript=None)
    state = {"sid": "STALE-OLD"}
    ls.resolve_session = lambda ws: state["sid"]

    def take_over():
        state["sid"] = "FRESH-NEW"          # the relaunch happened: the binding moved
        return ls.new_session("new.jsonl")

    obs = R.relaunch("ws-1", ls=ls, runner=FakeCmux(on_send=take_over), pi=sys.executable,
                     cwd="/tmp/lane", new=True, sleep=lambda _s: None, clock=_clock())
    assert obs["confirmed"] is True, obs
    assert obs["sid"] == "FRESH-NEW", obs


def test_new_does_not_confirm_when_the_baseline_could_not_be_READ(R, tmp_path, monkeypatch):
    """⛔ THE ROUND-3 P1, and it is the SAME false CONFIRM through a different door.

    `glob.glob` returns `[]` on an unreadable directory instead of raising, so the old baseline read
    an unreadable root as an EMPTY one. If the root became readable before the post-send read, every
    pre-existing transcript counted as "appeared" — exit 0 CONFIRMED for a session that existed
    BEFORE the relaunch. An unreadable baseline must yield no signal at all, never a transition.
    """
    ls = FakeLS(session="old", transcript=None)
    ls.new_session("old.jsonl")                  # present BEFORE the send, in the lane's own cwd
    cmux = FakeCmux()                            # the send succeeds and NOTHING changes

    real_listdir = os.listdir

    def blind(path):
        # the BASELINE walk is blinded; the post-send walk (a fresh call) works again
        raise PermissionError(13, "Permission denied", str(path))

    # Baseline = the first `_transcripts` call. Blind it, and only it.
    calls = {"n": 0}
    orig = R._transcripts

    def first_call_blind(lsd):
        calls["n"] += 1
        if calls["n"] == 1:
            return None                            # what an unreadable root must now yield
        return orig(lsd)

    monkeypatch.setattr(R, "_transcripts", first_call_blind)
    obs = R.relaunch("ws-1", ls=ls, runner=cmux, pi=sys.executable, cwd="/tmp/lane", new=True,
                     sleep=lambda _s: None, clock=_clock())
    assert calls["n"] >= 2, "the baseline was never taken — the test would be vacuous"
    assert obs.get("confirmed") is not True, (
        "an unreadable baseline confirmed a pre-existing transcript as a TRANSITION: %r" % (obs,))


def test_transcripts_returns_None_when_the_root_cannot_be_read(R, monkeypatch):
    """`_transcripts` must DISTINGUISH absent from unreadable: `glob.glob` cannot (it returns `[]`),
    which made the documented `None` arm dead code (review round 3, P1)."""
    ls = FakeLS()
    assert R._transcripts(ls) == set(), "an EMPTY-but-readable root is an empty baseline"
    absent = FakeLS()
    absent._session_dir = os.path.join(absent._root, "never-created")
    absent._root = os.path.join(absent._root, "also-never-created")
    assert R._transcripts(absent) == set(), "an ABSENT root holds no transcripts that could pre-exist"
    real_scandir = os.scandir

    def boom(path):
        raise PermissionError(13, "Permission denied", str(path))

    monkeypatch.setattr(os, "scandir", boom)
    assert R._transcripts(ls) is None, "an UNREADABLE root must be None, not an empty set"
    monkeypatch.setattr(os, "scandir", real_scandir)


def test_transcripts_treats_an_UNREACHABLE_root_as_None_not_as_absent(R, monkeypatch):
    """⛔ `os.path.isdir` SWALLOWS EVERY `OSError` (review round 4, P2) — EACCES on an untraversable
    parent, ESTALE/EIO on a network mount, ELOOP — so those read as a valid EMPTY baseline and
    re-opened the false-CONFIRM this function exists to prevent. Only `ENOENT` is an absence."""
    ls = FakeLS()
    real_stat = os.stat

    def stale(path, *a, **kw):
        raise OSError(116, "Stale file handle")

    monkeypatch.setattr(os, "stat", stale)
    assert R._transcripts(ls) is None, (
        "a root we could not REACH must be UNKNOWN, not an empty baseline")

    def enoent(path, *a, **kw):
        raise FileNotFoundError(2, "No such file or directory", str(path))

    monkeypatch.setattr(os, "stat", enoent)
    assert R._transcripts(ls) == set(), "an ABSENT root is still an absence, not UNKNOWN"
    monkeypatch.setattr(os, "stat", real_stat)


def test_new_reads_the_NEWEST_transcripts_not_the_first_five(R):
    """⛔ THE CANDIDATE WINDOW IS A SAFETY PROPERTY, SO IT MUST BE PINNED (review round 5, P2).

    `sorted(new_files)[:5]` kept the five that sort FIRST lexicographically, and a transcript
    filename is a session uuid — so on a box where five other lanes appear inside `--wait`, the file
    THIS relaunch created is the one dropped, and proof (i) silently degrades to proof (ii). The
    ordering is not cosmetic: it is what "appeared after the send" means. Reverting to the old form
    must go RED, which is exactly what this row does.
    """
    ls = FakeLS(transcript=None, session=None)

    def take_over():
        # FIVE other lanes start inside the window too, and they all sort BEFORE ours.
        for i in range(5):
            ls.new_session("aa%02d.jsonl" % i, cwd="/tmp/other-lane-%d" % i)
        ours = ls.new_session("zz-ours.jsonl", cwd="/tmp/lane")
        # Our transcript is the NEWEST by mtime, which is the property the tool must use. utime is
        # explicit so the row cannot pass or fail on same-second timestamp luck.
        now = 1_700_000_000
        for i in range(5):
            os.utime(os.path.join(ls._session_dir, "aa%02d.jsonl" % i), (now + i, now + i))
        os.utime(ours, (now + 100, now + 100))
        return ours

    obs = R.relaunch("ws-1", ls=ls, runner=FakeCmux(on_send=take_over), pi=sys.executable,
                     cwd="/tmp/lane", new=True, sleep=lambda _s: None, clock=_clock())
    assert obs["confirmed"] is True, (
        "the newest transcript was outside the candidate window, so a real fresh session went "
        "unconfirmed: %r" % (obs,))
    assert "fresh session appeared" in obs["reason"], obs


def test_dry_run_has_its_own_exit_code_never_CONFIRMED(R, monkeypatch, capsys):
    """⛔ `--dry-run` returned 0, and 0 is CONFIRMED — "sent AND advanced" — in this tool's own EXIT
    table (review round 4, P2). A scripted caller reading `$?` was told the lane came back by a run
    that sent nothing."""
    def fake(*_a, **_kw):
        return {"ws": "w-1", "confirmed": False, "refused": False, "sent": False,
                "reason": "dry run — nothing sent", "line": "cd /x && pi", "elapsed_s": 0.0}

    monkeypatch.setattr(R, "relaunch", fake)
    monkeypatch.setattr(sys, "argv", ["lane-relaunch.py", "--ws", "w-1", "--dry-run"])
    rc = R.main()
    out = capsys.readouterr().out
    assert rc not in (0, 1, 3, 4), "dry-run borrowed another outcome's code: rc=%r" % rc
    assert "DRY-RUN" in out, out


def test_new_does_not_confirm_on_a_transcript_that_predates_the_send(R):
    """⛔ THE ROUND-2 P1, pinned HONESTLY: a transcript that already existed before the send (a dead
    lane whose recorded id still has one — the common shape) is a STATE, not a transition."""
    ls = FakeLS(session="old", transcript=None)
    ls.new_session("old.jsonl")                  # present BEFORE the relaunch
    cmux = FakeCmux()                            # the send succeeds and NOTHING changes
    obs = R.relaunch("ws-1", ls=ls, runner=cmux, pi=sys.executable, cwd="/tmp/lane", new=True,
                     sleep=lambda _s: None, clock=_clock())
    assert obs["refused"] is False, obs
    assert obs["sent"] is True, obs
    assert obs["confirmed"] is False, "confirmed from a pre-send transcript: %r" % (obs,)


def test_new_confirms_when_the_pane_leaves_the_shell_prompt(R):
    """Proof (ii) — and the one that does not depend on a transcript at all: pi creates its session
    file LAZILY (`session-manager.js:691-715` assigns a path; the first write comes with the first
    entry), so a fresh session with no prompt may leave no file. The pane leaving the shell prompt is
    the transition, and it takes TWO consecutive reads so a redraw cannot confirm alone."""
    ls = FakeLS(transcript=None, session=None,
                screen=["dev@box repo % ", "pi tui line", "  /800k  -flash • high"])
    obs = R.relaunch("ws-1", ls=ls, runner=FakeCmux(), pi=sys.executable, cwd="/tmp/lane", new=True,
                     sleep=lambda _s: None, clock=_clock())
    assert obs["confirmed"] is True, obs
    assert "left the shell prompt" in obs["reason"], obs


def test_new_does_not_confirm_on_a_SINGLE_non_prompt_read(R):
    """Why the pane proof needs TWO consecutive reads: a redraw can leave one non-prompt frame. A
    single frame is not evidence that pi owns the pane."""
    ls = FakeLS(transcript=None, session=None,
                screen=["dev@box repo % ", "  (redraw noise)  ", "dev@box repo % "])
    obs = R.relaunch("ws-1", ls=ls, runner=FakeCmux(), pi=sys.executable, cwd="/tmp/lane", new=True,
                     sleep=lambda _s: None, clock=_clock())
    assert obs["refused"] is False, obs
    assert obs["confirmed"] is False, obs


def test_new_stays_unconfirmed_while_the_pane_is_still_a_shell(R):
    """The mirror: a launch line that failed leaves the prompt, so nothing is confirmed."""
    ls = FakeLS(transcript=None, session=None, screen="dev@box repo % ")
    obs = R.relaunch("ws-1", ls=ls, runner=FakeCmux(), pi=sys.executable, cwd="/tmp/lane", new=True,
                     sleep=lambda _s: None, clock=_clock())
    assert obs["confirmed"] is False, obs
    assert obs["sent"] is True


def test_dry_run_sends_nothing_and_prints_the_line(R, tmp_path):
    path = _transcript(tmp_path)
    cmux = FakeCmux()
    obs = _run(R, FakeLS(transcript=path), cmux, dry_run=True)
    assert cmux.sent() == []
    assert obs["line"].startswith("cd /tmp/lane && %s --session s-1" % sys.executable)
    assert obs["refused"] is False


def test_the_payload_never_execs_the_panes_shell_away(R, tmp_path):
    """⛔ `exec` REPLACES the pane's shell with pi, so a later pi exit takes the process — and with it
    the surface, and (on the only-surface case) the workspace: #942's own chain, one process-identity
    change away, hours later. pi as a CHILD keeps the bare-shell state this tool exists to act on.
    This row is the mutation target for a future reintroduction."""
    cmux = FakeCmux()
    _run(R, FakeLS(transcript=_transcript(tmp_path)), cmux)
    payload = cmux.sent()[0][-1]
    assert " exec " not in payload, "an exec'd payload hands the pane's process to pi: %r" % payload
    assert "&& exec" not in payload, payload
    assert payload.startswith("cd /tmp/lane && /"), payload


# ── R4: the tool must never be the destructive verb it exists to replace -----------------------
def _fold_argv(node):
    """Constant-fold an argv-ish expression to a str or a LIST of strings/None.

    Exists so the source check reads an ASSEMBLED argv as the value it evaluates to: `"respawn" +
    "-pane"` must fold to the single string `"respawn-pane"`, because a token-level regex cannot see
    it — and because folding it into two list entries would let `"send" + "x"` pass as `send`. `None`
    marks a part the folder could not resolve (a Name, a call, a starred element), so the caller can
    demand a BOUNDED VERB without demanding that every argument be a literal, since a real argv
    legitimately carries variables.
    """
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left, right = _fold_argv(node.left), _fold_argv(node.right)
        if left is None or right is None:
            return None
        if isinstance(left, str) and isinstance(right, str):
            return left + right                     # adjacent literals JOIN
        lseq = left if isinstance(left, list) else [left]
        rseq = right if isinstance(right, list) else [right]
        return lseq + rseq
    if isinstance(node, (ast.List, ast.Tuple)):
        out = []
        for elt in node.elts:
            if isinstance(elt, ast.Starred):
                out.append(None)
                continue
            val = _fold_argv(elt)
            if isinstance(val, str):
                out.append(val)
            elif isinstance(val, list):
                out.extend(val)
            else:
                out.append(None)
        return out
    return None


def test_no_destructive_verb_on_any_path(R, tmp_path):
    """Every path the tool can take, every argv it builds, checked against the verb list.

    ⛔ THE BLOB ARM BELOW IS A BACKSTOP, NOT THE GUARD (review obs 1): `_forbidden_in` refuses before
    any argv is recorded, so a forbidden verb cannot appear in `seen` unless the tripwire is gone — in
    which case `fresh_sent`/`seen` still exist and the source scan is what reds. The tripwire's OWN
    behaviour is pinned by `test_every_forbidden_verb_is_caught_by_the_tripwire` and
    `test_the_tripwire_fires_on_a_REAL_path_before_any_send`."""
    path = _transcript(tmp_path)
    scenarios = [
        dict(ls=FakeLS(transcript=path), cmux=FakeCmux()),
        dict(ls=FakeLS(transcript=path), cmux=FakeCmux(on_send=lambda: open(path, "a").write("{}\n"))),
        dict(ls=FakeLS(working=True), cmux=FakeCmux()),
        dict(ls=FakeLS(screen="no prompt here"), cmux=FakeCmux()),
        dict(ls=FakeLS(transcript=None), cmux=FakeCmux()),
        dict(ls=FakeLS(cwd=None), cmux=FakeCmux()),
        # ⛔ THE `--new` ARM IS A PATH TOO (review finding 1, 2026-11-08). The sweep covered only the
        # resume arm, so a destructive verb added inside the `fresh` branch kept this suite green —
        # while the PR claims "every argv on every path". Both the refusal and the send side of the
        # fresh arm are exercised here, because they build different argv.
        dict(ls=FakeLS(transcript=path), cmux=FakeCmux(), new=True),
        dict(ls=FakeLS(transcript=None), cmux=FakeCmux(), new=True),
        dict(ls=FakeLS(working=True), cmux=FakeCmux(), new=True),
        dict(ls=FakeLS(screen="no prompt here"), cmux=FakeCmux(), new=True),
        dict(ls=FakeLS(cwd=None), cmux=FakeCmux(), new=True),
        dict(ls=FakeLS(transcript=path), cmux=FakeCmux(on_send=lambda: None), new=True),
        # ⛔ THE SEND-FAILURE PATH IS A PATH TOO (review round 2, P1). No scenario used `send_rc != 0`,
        # so a "fall back to respawn-pane when the send fails" mutation — the exact hazard this tool
        # exists to prevent — kept the suite green while the tool emitted the destructive verb. The
        # failure branch is precisely where an author is tempted to reach for the verb "just to retry".
        dict(ls=FakeLS(transcript=path), cmux=FakeCmux(send_rc=1)),
        dict(ls=FakeLS(transcript=path), cmux=FakeCmux(send_rc=1), new=True),
        dict(ls=FakeLS(transcript=path), cmux=FakeCmux(on_send=lambda: None, send_rc=3)),
        dict(ls=FakeLS(transcript=path), cmux=FakeCmux(on_send=lambda: None, send_rc=3), new=True),
    ]
    seen = []
    fresh_sent = 0
    for sc in scenarios:
        cmux = sc.pop("cmux")
        _run(R, sc.pop("ls"), cmux, **sc)
        seen.extend(cmux.calls)
        fresh_sent += len([c for c in cmux.calls if c[:2] == ["cmux", "send"]])
    assert seen, "no argv was recorded — the test is vacuous"
    # ⛔ NOT VACUOUS (review finding 1): the fresh arm must actually have REACHED the send. A sweep
    # whose `--new` scenarios all refused would pass without ever building the fresh argv.
    assert fresh_sent >= 2, "the `--new` arm never reached a send; the sweep is vacuous there"
    blob = "\n".join(" ".join(c) for c in seen)
    for verb in R.FORBIDDEN_VERBS:
        assert verb not in blob, "a forbidden verb was emitted: %s" % verb
    src = open(_MINE).read()
    # ⛔ VERB-BLIND, NOT LITERAL (review finding 1): the old check matched only the exact spelling
    # `["cmux", "respawn-pane"`, so `"respawn" + "-pane"` walked straight through it. This walks
    # every argv-shaped expression, CONSTANT-FOLDS string concatenation, and requires the verb of any
    # list that starts with `"cmux"` to be a member of the allowed set — so an assembled verb is
    # checked as the value it evaluates to, not as the tokens it was written from. It also refuses a
    # cmux argv it cannot statically bound (a variable verb), because no test can bound that: an argv
    # built from a name is a hole this file would otherwise report as covered.
    allowed = {"send", "sessions", "read-screen"}
    tree = ast.parse(src)
    checked = 0
    for node in ast.walk(tree):
        if not isinstance(node, (ast.List, ast.BinOp, ast.Tuple)):
            continue
        seq = _fold_argv(node)
        if not isinstance(seq, list) or "cmux" not in seq:
            continue
        checked += 1
        i = seq.index("cmux")
        # The VERB position must be bounded. An argv that reaches `cmux` and then a name is a hole
        # this file would otherwise report as covered — the arguments after the verb are free to be
        # variables, the verb is not.
        assert i + 1 < len(seq) and seq[i + 1] is not None, (
            "line %d builds a cmux argv whose verb is not statically bounded, so no test can assert "
            "it" % node.lineno)
        assert seq[i + 1] in allowed, (
            "line %d builds the cmux verb %r, outside %s" % (node.lineno, seq[i + 1], sorted(allowed)))
        joined = " ".join(s for s in seq if s is not None)
        # ⛔ THE TABLE, NOT A HAND-SPELLED SUBSET (review obs 1, 2026-11-08): the literal triple that
        # stood here missed `respawn_pane`, `close_workspace`, `kill_pane` and `terminal close` — the
        # spellings the tool would grow first, since a rewrite reaching for the verb rarely types the
        # hyphenated form. One table, shared with the tool, is the only version that cannot drift.
        for verb in R.FORBIDDEN_VERBS:
            assert verb not in joined, (
                "line %d builds a destructive verb: %r" % (node.lineno, joined))
    assert checked, "no cmux argv was bound by the source check — is the argv construction gone?"
    # and no NON-docstring string constant anywhere may spell a destructive verb (an argv assembled
    # over several statements has no `["cmux", …]` shape to match, so the shape check above alone
    # would miss it). Docstrings and comments are excluded on purpose: they are prose ABOUT the
    # hazard, which is the whole point of the file. The `FORBIDDEN_VERBS` table is excluded because
    # it is the definition of the list, not a use of it.
    tree = ast.parse(src)
    defin = set()
    for node in ast.walk(tree):
        if (isinstance(node, ast.Assign)
                and any(getattr(t, "id", None) == "FORBIDDEN_VERBS" for t in node.targets)):
            for sub in ast.walk(node.value):
                defin.add(id(sub))
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            body = getattr(node, "body", None) or []
            if (body and isinstance(body[0], ast.Expr)
                    and isinstance(body[0].value, ast.Constant)
                    and isinstance(body[0].value.value, str)):
                docstrings.add(id(body[0].value))
    # argparse's user-facing prose is the other legitimate channel for naming the hazard — an
    # operator reading `--help` is exactly who must be told the tool never uses that verb.
    for node in ast.walk(tree):
        if isinstance(node, ast.keyword) and node.arg in ("description", "help", "epilog"):
            for sub in ast.walk(node.value):
                docstrings.add(id(sub))
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Constant) and isinstance(node.value, str)):
            continue
        if id(node) in defin or id(node) in docstrings:
            continue
        for verb in R.FORBIDDEN_VERBS:
            assert verb not in node.value, (
                "a string constant outside a docstring spells a destructive verb (line %d): %r"
                % (node.lineno, node.value))


# ── the tripwire itself (review obs 1, 2026-11-08) ─────────────────────────────────────────────
def test_every_forbidden_verb_is_caught_by_the_tripwire(R):
    """⛔ THE SWEEP'S BLOB ARM CANNOT EXERCISE THE TRIPWIRE, WHICH IS WHAT MADE IT VACUOUS (review
    obs 1). `_forbidden_in` refuses BEFORE an argv is recorded, so `seen` is clean by construction and
    no assertion over it can red for a forbidden verb. The tripwire is what the PR's headline safety
    claim rests on, so it is pinned directly: every verb in the table must be DETECTED, the real
    launch shape must pass, and the table must not be quietly shortened.

    Non-vacuity: `return ""` (delete the scan) reds the loop; dropping a spelling from
    `FORBIDDEN_VERBS` reds the coverage arm below. That coverage arm states the concepts HERE rather
    than deriving them from the same tuple, because a row that iterates the table cannot notice the
    table shrinking.
    """
    for verb in R.FORBIDDEN_VERBS:
        assert R._forbidden_in(["cmux", "send", "--workspace", "ws-1", "cd /x && " + verb]) == verb, (
            "`_forbidden_in` did not catch %r" % verb)
    assert R._forbidden_in(
        ["cmux", "send", "--workspace", "ws-1", "cd /tmp/lane && /usr/bin/pi --session s-1\n"]) == "", (
        "the tripwire refuses a legitimate launch line")
    for concept, spellings in {"respawn": ("respawn-pane", "respawn_pane"),
                               "close": ("close-workspace", "close_workspace"),
                               "kill": ("kill-pane", "kill_pane")}.items():
        for sp in spellings:
            assert sp in R.FORBIDDEN_VERBS, (
                "FORBIDDEN_VERBS lost the %s spelling %r" % (concept, sp))


def test_the_tripwire_fires_on_a_REAL_path_before_any_send(R, tmp_path):
    """The END-TO-END companion to the row above.

    `_forbidden_in` substring-scans the whole payload INCLUDING the cwd (review obs 4 — fail-closed,
    a note not a defect), so a lane whose worktree is named e.g. `close-workspace-test` reaches the
    tripwire on an ordinary resume-arm run. That is the ONE path on which the tripwire is reachable
    from outside the tool, so it is used to prove the refusal happens BEFORE anything is typed.

    Non-vacuity: delete the `bad = _forbidden_in(argv)` / `if bad:` arm and the send proceeds —
    `refused` False and `cmux.sent()` non-empty. Drop a spelling from `FORBIDDEN_VERBS` and the same
    happens, so this row pins the table end-to-end, not just the scanner.
    """
    path = _transcript(tmp_path)
    lane = tmp_path / "close-workspace-lane"
    lane.mkdir()
    cmux = FakeCmux()
    obs = _run(R, FakeLS(transcript=path), cmux, cwd=str(lane))
    assert obs["refused"] is True, obs
    assert "REFUSING" in obs["reason"], obs
    assert cmux.sent() == [], "a destructive-verb payload reached the pane: %r" % (cmux.calls,)


# ── the reporting layer (review finding 1) ────────────────────────────────────────────────────
def test_missing_lane_status_is_a_named_refusal_not_a_crash(R):
    """`pi-bootstrap` withholds `lane-status.py` by decision (#1553), so "drop the tool beside the
    farmed heartbeat" is a natural install that leaves the imports absent. That must be a REFUSAL
    that says so — not an exception, and never a silent DRY-RUN."""
    def boom():
        raise FileNotFoundError("lane-status.py")
    orig = R._load_lane_status
    R._load_lane_status = boom
    try:
        obs = R.relaunch("ws-1", runner=FakeCmux(), pi=sys.executable, cwd="/tmp")
    finally:
        R._load_lane_status = orig
    assert obs["refused"] is True, obs
    assert "no lane-status.py beside this tool" in obs["reason"]


def test_main_reports_a_crash_as_error_never_dry_run(R, monkeypatch, capsys):
    """The label ladder's `else` arm used to swallow the crash: an operator was told DRY-RUN and
    handed exit 4 ("sent, but unconfirmed") for a run that read nothing and sent nothing."""
    def boom(*_a, **_kw):
        raise RuntimeError("boom")
    monkeypatch.setattr(R, "relaunch", boom)
    monkeypatch.setattr(sys, "argv", ["lane-relaunch.py", "--ws", "w-1"])
    rc = R.main()
    out = capsys.readouterr().out
    assert rc not in (0, 3, 4), "a crash must not borrow REFUSED/OK/UNCONFIRMED's code: rc=%r" % rc
    assert "ERROR" in out, out
    assert "DRY-RUN" not in out, out
    assert "[Nones]" not in out, out


def test_session_id_is_quoted_in_the_payload(R, tmp_path):
    """The residual from the review: cwd and pi were quoted, the operator-supplied id was not."""
    path = _transcript(tmp_path)
    cmux = FakeCmux()
    obs = R.relaunch("ws-1", ls=FakeLS(session="a b; rm -rf x", transcript=path), runner=cmux,
                     pi=sys.executable, cwd="/tmp/lane", sleep=lambda _s: None, clock=_clock())
    line = cmux.sent()[0][-1]
    assert obs["refused"] is False, obs
    assert "--session 'a b; rm -rf x'" in line or '--session "a b; rm -rf x"' in line, line


# ── R6: the regression that produced this issue — a remedy that does not exist ------------------
def _farm_arrays():
    """The names `pi-bootstrap/setup.sh` actually DELIVERS, plus the names it declares withheld.

    R6 has two halves and the first one is not enough: a name that exists in the checkout is still
    unreachable from a box where only the farmed copy of the message lives. This reads the farm so
    the answer is DERIVED from what ships, never a hand list that can fall behind it.
    """
    src = open(os.path.join(_REPO, "pi-bootstrap", "setup.sh")).read()
    farmed, withheld = set(), set()
    # Anywhere, not line-anchored: `lane_root_srcs=` is declared inside a comment block, so an
    # anchored pattern reads as empty and silently turns the whole derivation vacuous.
    for m in re.finditer(r'(\w*_srcs)\s*=\s*\(([^)]*)\)', src):
        name, body = m.group(1), m.group(2)
        words = set(re.findall(r"[\w.\-/]+\.(?:py|sh)", body))
        (withheld if "root" in name else farmed).update(words)
    assert farmed, "read no farmed sources from pi-bootstrap/setup.sh — did the farm move?"
    return farmed, withheld


def _landing_form(name, farmed, withheld):
    """The path idiom a FARMED consumer file must use to reach `name`.

    A farmed file runs at `$HOME/.pi/agent/scripts`, so a bare repo-relative `scripts/x` resolves to
    nothing there. If the name is in the farm, `$SCRIPTS/x` is right (the heartbeat's own directory).
    If it is NOT farmed, `$SCRIPTS/x` is just as wrong as `scripts/x` — the honest answer is the
    checkout the operator is told to have: `$AGENT_INFRA_PATH/scripts/x`.
    """
    if name in farmed:
        return "$SCRIPTS/%s" % name
    return "$AGENT_INFRA_PATH/scripts/%s" % name


def test_beat_remedy_names_a_script_that_exists():
    """`orchestrator-heartbeat.sh`'s DEAD LANES clause used to prescribe `recover-fleet / relaunch`
    — neither exists in the repo or the farm — so the operator improvised, and the improvisation
    was the verb that deletes workspaces (#942). Pin the name to a real file."""
    beat = open(os.path.join(_HERE, "orchestrator-heartbeat.sh")).read()
    m = re.search(r'DEAD LANES[^"]*', beat)
    assert m, "the DEAD LANES clause is gone — did the wiring get lost?"
    clause = m.group(0)
    assert "RELAUNCH" in clause, clause
    assert "recover-fleet" not in clause, "the clause is back to naming `recover-fleet`, which does not exist"
    named = re.findall(r"scripts/[\w.\-/]+\.(?:py|sh)", clause)
    assert named, "the DEAD LANES clause names no script: %r" % (clause,)
    # ⛔ THE CLASS, NOT ONE CLAUSE (review finding 2, 2026-11-08): the SAME dangling pointer survived
    # in this file's own comment two lines above the clause the first fix touched, because the check
    # only looked at one `[^"]*` window. Assert over the WHOLE file. §47 (`the board's §47` advice for
    # a CHILD-STUCK verdict) is deliberately NOT asserted: it is pinned into six goldens and is not
    # this change's to churn — scope here is §72, the relaunch mechanism.
    assert "ORCHESTRATION-BOARD \u00a772" not in beat, (
        "the heartbeat still credits the relaunch mechanism to a board doc that is on no box (§72)")
    for rel in named:
        p = os.path.join(_REPO, rel)
        assert os.path.exists(p), "the beat names a nonexistent script: %s" % rel
        # ⛔ `exists` cannot tell "present" from "runnable", and every instruction names a BARE PATH
        # (review round 4, P1: the tool shipped 100644 and the first command an operator runs after
        # reading the beat was `Permission denied` — which puts `respawn-pane` back within reach).
        assert os.access(p, os.X_OK), "the beat prescribes a bare path that is not executable: %s" % rel
    # ⛔ AND IT MUST BE REACHABLE FROM WHERE THE MESSAGE LIVES (review finding 2, 2026-11-08). The
    # clause is delivered to `$HOME/.pi/agent/scripts`, so a repo-relative `scripts/x` resolves to
    # nothing there: the operator reads a remedy, types it, gets `No such file` — and improvises with
    # the destructive verb, which is the entire defect of #942. The form is DERIVED from the farm
    # arrays rather than written here, so it follows the delivery if #1553 ever farms the producer.
    farmed, withheld = _farm_arrays()
    for rel in named:
        base = os.path.basename(rel)
        want = _landing_form(base, farmed, withheld)
        assert want in clause, (
            "the DEAD LANES clause must name %r (it is %s by the farm), got: %r"
            % (want, "farmed" if base in farmed else "NOT farmed", clause))
        assert not re.search(r'(?<![/\w$.])scripts/%s' % re.escape(base), clause), (
            "the clause names a bare repo-relative path for %r, which resolves to nothing on the "
            "box that receives this message: %r" % (base, clause))
    # Why the checkout form is required rather than "just farm the tool": the producer imports a
    # module the farm withholds by decision (#1553), so farming it alone would ship a tool that
    # cannot import. If that decision is ever reversed, this test says so instead of going stale.
    assert "lane-status.py" in withheld, (
        "lane-status.py is no longer declared withheld by the farm — if #1553 landed, re-derive the "
        "landing form rather than assuming this test's premise")


def test_safe_send_remedy_is_reachable():
    """The same dangling pointer lived in `safe-send.sh`'s refusal message — and that file is farmed
    too, so it carries the same reachability requirement as the beat."""
    s = open(os.path.join(_HERE, "safe-send.sh")).read()
    assert "ORCHESTRATION-BOARD 72" not in s, "safe-send still points at a board doc that is not on the box"
    assert "lane-relaunch.py" in s, "safe-send's refusal names no reachable relaunch"
    # ⛔ Reachable FROM A FARMED BOX, not merely on disk (review finding 2): `safe-send.sh` is in
    # `fleet_srcs`, so at runtime `dirname $0` is `$HOME/.pi/agent/scripts` and a bare `scripts/…`
    # would name a directory that is not there. Same derived form as the beat.
    farmed, withheld = _farm_arrays()
    want = _landing_form("lane-relaunch.py", farmed, withheld)
    assert want in s, "safe-send must name %r, the form reachable from where it runs" % want
    assert not re.search(r'(?<![/\w$.])scripts/lane-relaunch\.py', s), (
        "safe-send names a bare repo-relative path, which resolves to nothing on the box that "
        "receives this message")
