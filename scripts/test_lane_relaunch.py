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
import importlib.util
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
                 cwd="/tmp/lane"):
        self._screen = screen
        self._working = working
        self._session = session
        self._transcript = transcript
        self._cwd = cwd

    def read_screen(self, ws, lines=14):
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
    """rc=0 with EMPTY stdout is not an answer either (a renamed key after a cmux bump)."""
    cmux = FakeCmux(record_out="")
    obs = _run(R, FakeLS(), cmux)
    assert obs["refused"] is True
    assert cmux.sent() == []


def test_refuses_when_pane_unreadable(R):
    cmux = FakeCmux()
    obs = _run(R, FakeLS(screen="   \n  "), cmux)
    assert obs["refused"] is True
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
    assert line.startswith("cd /tmp/lane && exec %s --session s-1" % sys.executable)
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


class ScriptLS(FakeLS):
    """A lane-status whose answers CHANGE between calls, so a transition can be told from a state.

    `resolve_session` returns the next scripted value (the last one repeats); `session_file` maps an
    id to a path. This is the only way to express "the SAME id already had a transcript before the
    send" — the shape that made the fresh arm report a false CONFIRMED (review round 2, P1).
    """

    def __init__(self, resolve_seq, files, **kw):
        super().__init__(**kw)
        self._seq = list(resolve_seq)
        self._files = dict(files)

    def resolve_session(self, ws):
        if len(self._seq) > 1:
            return self._seq.pop(0)
        return self._seq[0]

    def session_file(self, sid):
        return self._files.get(sid)


def test_new_does_not_confirm_from_a_binding_that_predates_the_send(R, tmp_path):
    """The P1 from review round 2: `--new` on a lane whose RECORDED id still has a transcript on
    disk — the common shape — used to print CONFIRMED (exit 0) on the FIRST loop iteration, from a
    session nothing had started. A state is not a transition."""
    stale = tmp_path / "old.jsonl"
    stale.write_text("{}\n")
    ls = ScriptLS(resolve_seq=["old", "old"], files={"old": str(stale)})
    cmux = FakeCmux()          # the send "succeeds" and NOTHING changes on disk
    obs = R.relaunch("ws-1", ls=ls, runner=cmux, pi=sys.executable, cwd="/tmp/lane", new=True,
                     sleep=lambda _s: None, clock=_clock())
    assert obs["sent"] is True, obs
    assert obs["confirmed"] is False, "confirmed from the pre-send binding: %r" % (obs,)
    assert cmux.sent()[0][-1].count("--session") == 0


def test_new_confirms_when_the_binding_CHANGES(R, tmp_path):
    """The transition that IS proof: a different id resolves to a real transcript."""
    stale = tmp_path / "old.jsonl"
    stale.write_text("{}\n")
    fresh_f = tmp_path / "new.jsonl"
    fresh_f.write_text("{}\n")
    ls = ScriptLS(resolve_seq=["old", "new", "new"], files={"old": str(stale), "new": str(fresh_f)})
    obs = R.relaunch("ws-1", ls=ls, runner=FakeCmux(), pi=sys.executable, cwd="/tmp/lane", new=True,
                     sleep=lambda _s: None, clock=_clock())
    assert obs["confirmed"] is True, obs
    assert obs["sid"] == "new"


def test_new_confirms_when_the_SAME_id_gets_a_transcript(R, tmp_path):
    """The arm's motivating case: the recorded id had NO file (a stale resume target). The same id
    resolving to a file that did not exist at the baseline is a real appearance."""
    fresh_f = tmp_path / "old.jsonl"
    ls = ScriptLS(resolve_seq=["old", "old"], files={})
    cmux = FakeCmux(on_send=lambda: (fresh_f.write_text("{}\n"), ls._files.__setitem__("old", str(fresh_f))))
    obs = R.relaunch("ws-1", ls=ls, runner=cmux, pi=sys.executable, cwd="/tmp/lane", new=True,
                     sleep=lambda _s: None, clock=_clock())
    assert obs["confirmed"] is True, obs


def test_dry_run_sends_nothing_and_prints_the_line(R, tmp_path):
    path = _transcript(tmp_path)
    cmux = FakeCmux()
    obs = _run(R, FakeLS(transcript=path), cmux, dry_run=True)
    assert cmux.sent() == []
    assert obs["line"].startswith("cd /tmp/lane && exec %s --session s-1" % sys.executable)
    assert obs["refused"] is False


# ── R4: the tool must never be the destructive verb it exists to replace -----------------------
def test_no_destructive_verb_on_any_path(R, tmp_path):
    """Every path the tool can take, every argv it builds, checked against the verb list. This is
    the test that fails if someone 'fixes' the tool into `respawn-pane`."""
    path = _transcript(tmp_path)
    scenarios = [
        dict(ls=FakeLS(transcript=path), cmux=FakeCmux()),
        dict(ls=FakeLS(transcript=path), cmux=FakeCmux(on_send=lambda: open(path, "a").write("{}\n"))),
        dict(ls=FakeLS(working=True), cmux=FakeCmux()),
        dict(ls=FakeLS(screen="no prompt here"), cmux=FakeCmux()),
        dict(ls=FakeLS(transcript=None), cmux=FakeCmux()),
        dict(ls=FakeLS(cwd=None), cmux=FakeCmux()),
    ]
    seen = []
    for sc in scenarios:
        cmux = sc["cmux"]
        _run(R, sc["ls"], cmux)
        seen.extend(cmux.calls)
    assert seen, "no argv was recorded — the test is vacuous"
    blob = "\n".join(" ".join(c) for c in seen)
    for verb in R.FORBIDDEN_VERBS:
        assert verb not in blob, "a forbidden verb was emitted: %s" % verb
    # and the tool's own source names no such call site (a comment is fine, a call is not)
    src = open(_MINE).read()
    assert not re.search(r'\[\s*"cmux"\s*,\s*"(respawn-pane|close-workspace|kill-pane)"', src)


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
        assert os.path.exists(os.path.join(_REPO, rel)), "the beat names a nonexistent script: %s" % rel


def test_safe_send_remedy_is_reachable():
    """The same dangling pointer lived in `safe-send.sh`'s refusal message."""
    s = open(os.path.join(_HERE, "safe-send.sh")).read()
    assert "ORCHESTRATION-BOARD 72" not in s, "safe-send still points at a board doc that is not on the box"
    assert "lane-relaunch.py" in s, "safe-send's refusal names no reachable relaunch"
