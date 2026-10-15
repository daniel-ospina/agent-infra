#!/usr/bin/env python3
"""test_lane_orchestration.py — the lane-orchestration layer's own regression pins (#1552).

The layer was versioned from live, untracked files, so its review findings are exactly the
class that ships as SILENT fleet behaviour. These tests pin three of them:

  * the stall screener inside ``scripts/lane/orchestrator-heartbeat.sh`` must resolve its
    path where expansion can happen AND must FAIL OPEN — a missing or crashing screener
    alerts instead of suppressing every WEAK verdict (the whole stall/idle family);
  * ``lane-triage.py`` is invoked from the FARMED copy (``$SCRIPTS``), not the ``state/``
    path ``pi-bootstrap/setup.sh`` never provisions;
  * every ``scripts/lane/*.sh`` is inside CI's bash syntax sweep (``SWEEP_GLOBS``);
  * the lane classifier has ONE home after the #1553 rebase (main's promoted ``scripts/``
    copies), not a second Oct-1 snapshot under ``scripts/lane/``.

Each behavioural assertion is written to FAIL on the pre-fix source — the non-vacuity
proof for the P1/P2 findings. The screener block is extracted VERBATIM from the shell file
and executed as a subprocess against synthetic lane rows under a throwaway HOME, which is
how the finding was reproduced.

The second review round (#1553 @ 4304fef) added four findings, pinned here as well:

  * ``turn-classify.py``'s Jev door (``finished_the_work`` -> ``idle_next_work``) must
    re-verify idleness at the SEND boundary, exactly like the structural idle door —
    otherwise a lane that started a long tool call after the snapshot is sidetracked;
  * ``scripts/heartbeat-loop.sh`` must DERIVE its HOME/PATH from the environment, not
    hard-pin the author's home (which made the farmed loop a silent no-op);
  * ``lane-guard.py``'s ``--budget`` must bound the probe it declares a bound for, and
    each side must cost ONE pane read rather than read_screen + ui_working;
  * the stall-term registry must not advertise an ``IDLE_MIN`` bound no code reads.
"""
from __future__ import annotations

import glob
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent
HEARTBEAT = HERE / "lane" / "orchestrator-heartbeat.sh"
SHARDS = HERE / "run-bash-shards.sh"
SETUP = REPO_ROOT / "pi-bootstrap" / "setup.sh"
TURN_CLASSIFY = HERE / "lane" / "turn-classify.py"
LANE_GUARD = HERE / "lane" / "lane-guard.py"
LANE_TRIAGE = HERE / "lane" / "lane-triage.py"
LOOP = HERE / "heartbeat-loop.sh"
REGISTRY_TS = REPO_ROOT / "extensions" / "shared" / "heartbeat-progress-edges.ts"

# The stall-verdict Python is the single-quoted argument of the second `python3 -c '…'`.
_BLOCK_RE = re.compile(r"\| /usr/bin/python3 -c '\n(.*?)\n' 2>/dev/null\)", re.S)

# One WEAK verdict (the family that must never be silently suppressed) and one non-WEAK
# verdict (alerts unconditionally), so the assertion cannot pass by alerting everything.
ROWS = [
    {"lane": "LANE-WEDGED", "verdict": "WEDGED", "child": None, "stale_s": 900},
    {"lane": "LANE-EMPTY", "verdict": "EMPTY", "child": None, "stale_s": 900},
]


def _screener_python() -> str:
    src = HEARTBEAT.read_text(encoding="utf-8")
    m = _BLOCK_RE.search(src)
    assert m, f"could not locate the stall-verdict python block in {HEARTBEAT}"
    return m.group(1)


def _run_block(home: Path) -> str:
    """Execute the extracted block against ROWS under a throwaway HOME."""
    env = dict(os.environ, HOME=str(home))
    proc = subprocess.run(
        [sys.executable, "-c", _screener_python()],
        input=json.dumps(ROWS),
        capture_output=True,
        text=True,
        env=env,
        timeout=120,
    )
    assert proc.returncode == 0, f"screener block failed rc={proc.returncode}: {proc.stderr}"
    return proc.stdout.strip()


def _field(out: str, name: str) -> str:
    """`NAME="…"` from the `KEY="value";KEY="value";…` line the block prints."""
    m = re.search(rf'(?:^|;){name}="([^"]*)"', out)
    assert m, f"{name} not in screener output: {out!r}"
    return m.group(1)


def _write_screener(home: Path, rc: int) -> Path:
    """Install a fake screener that RECORDS that it ran, then exits with `rc`.

    The marker is what makes the negative-verdict test non-vacuous: pre-fix the block
    never runs any screener (the literal `$HOME` argv), so the marker is never written.
    """
    p = home / ".pi" / "agent" / "state" / "lane-confirm.py"
    p.parent.mkdir(parents=True, exist_ok=True)
    marker = home / ".screener-ran"
    p.write_text(
        "import sys, pathlib\n"
        f"pathlib.Path({str(marker)!r}).write_text('ran')\n"
        f"sys.exit({rc})\n",
        encoding="utf-8",
    )
    return marker


# ── P1: the screener's path resolution and its FAIL-OPEN contract ─────────────


def test_missing_screener_fails_open_and_the_weak_alert_fires(tmp_path):
    """No lane-confirm.py on the box ⇒ alert, never silent suppression.

    PRE-FIX this fails: the path was the literal token `$HOME/…` (bash expands nothing
    inside the single-quoted `-c` argument), python3 exited 2 on the missing file, and
    `rc == 0` read that as "not stalled" — so LANE-WEDGED landed in KNOWN[screened-ok].
    """
    out = _run_block(tmp_path)
    alerts = _field(out, "ALERTS")
    assert "LANE-WEDGED:WEDGED" in alerts, f"WEAK alert suppressed with no screener: {out!r}"
    assert "[screened-ok]" not in out, out


def test_present_screener_is_resolved_and_a_stalled_verdict_alerts(tmp_path):
    """A screener that exists at ~/.pi/agent/state must actually be invoked.

    rc=0 == STALLED, which must reach ALERTS. PRE-FIX the literal `$HOME` path means the
    real file is never found (rc=2), so the WEDGED lane is suppressed and this fails.
    """
    _write_screener(tmp_path, rc=0)
    out = _run_block(tmp_path)
    assert "LANE-WEDGED:WEDGED" in _field(out, "ALERTS"), out


def test_screener_negative_verdict_suppresses_but_stays_visible(tmp_path):
    """rc=1 == definitively NOT stalled: keep the verdict visible, out of ALERTS."""
    marker = _write_screener(tmp_path, rc=1)
    out = _run_block(tmp_path)
    assert marker.exists(), "the screener was never invoked — the path did not resolve"
    assert "LANE-WEDGED:WEDGED" not in _field(out, "ALERTS"), out
    assert "LANE-WEDGED:WEDGED[screened-ok]" in _field(out, "KNOWN"), out


def test_crashing_screener_fails_open(tmp_path):
    """A screener that ERRORS (rc=2) is 'could not run' — the docstring says alert.

    PRE-FIX rc=2 read as "not stalled" ⇒ suppressed ⇒ this fails.
    """
    _write_screener(tmp_path, rc=2)
    out = _run_block(tmp_path)
    assert "LANE-WEDGED:WEDGED" in _field(out, "ALERTS"), out


def test_screener_block_carries_no_unexpanded_home_token():
    """The block is a single-quoted `-c` argument, so a bare `$HOME` is a literal path."""
    assert '"$HOME/' not in _screener_python(), "an unexpanded $HOME path survives in the block"


# ── P1: lane-triage.py is read from the farmed copy ───────────────────────────


def test_lane_triage_is_invoked_from_the_farmed_copy():
    src = HEARTBEAT.read_text(encoding="utf-8")
    assert '"$SCRIPTS/lane-triage.py"' in src, "$SCRIPTS/lane-triage.py is not the call site"
    assert '"$HOME/.pi/agent/state/lane-triage.py"' not in src, (
        "the un-provisioned state/ path is still the call site — the farmed copy is inert"
    )


# ── P2: the lane shell files are inside CI's syntax sweep ─────────────────────


def test_every_lane_shell_file_is_swept_for_syntax():
    src = SHARDS.read_text(encoding="utf-8")
    m = re.search(r"SWEEP_GLOBS=\((.*?)\)", src, re.S)
    assert m, "SWEEP_GLOBS not found in run-bash-shards.sh"
    globs = re.findall(r'"([^"]+)"', m.group(1))
    # Use real shell-style globbing, NOT fnmatch: fnmatch's `*` crosses `/`, so it would
    # report `scripts/*.sh` as covering `scripts/lane/x.sh` and the gap would stay invisible.
    matched = set()
    for g in globs:
        matched.update(p.relative_to(REPO_ROOT).as_posix() for p in REPO_ROOT.glob(g) if p.is_file())
    lane_sh = sorted(p.name for p in (HERE / "lane").glob("*.sh"))
    assert lane_sh, "expected scripts/lane/*.sh to exist"
    for name in lane_sh:
        rel = f"scripts/lane/{name}"
        assert rel in matched, f"{rel} matches none of the SWEEP_GLOBS patterns {globs}"


# ── reconciliation: one home for the lane classifier ──────────────────────────


def test_the_lane_classifier_has_one_home():
    """No second, stale classifier after the rebase onto main's promoted copies."""
    assert not (HERE / "lane" / "lane-status.py").exists(), "stale lane-status.py snapshot"
    assert not (HERE / "lane" / "heartbeat-loop.sh").exists(), "stale heartbeat-loop.sh snapshot"
    assert (HERE / "lane-status.py").exists(), "missing the canonical scripts/lane-status.py"
    assert (HERE / "heartbeat-loop.sh").exists(), "missing the canonical scripts/heartbeat-loop.sh"
    setup = SETUP.read_text(encoding="utf-8")
    assert "lane_root_srcs=(lane-status.py heartbeat-loop.sh)" in setup, (
        "the farm must source the two promoted files from scripts/, not scripts/lane/"
    )


# ── P1 (review @4304fef): turn-classify.py's Jev door re-verifies at the boundary ──
#
# `idle_next_work` is the ONE nudge that ASSERTS the lane has nothing in flight. It is
# emitted from TWO doors: the structural DONE-IDLE/WIP-IDLE path (guarded) and the Jev
# `finished_the_work` path (UNGUARDED before this fix). The second door is kept, so the
# guard must be too — a lane that ended its previous turn and has since started a long
# tool call reaches it and would be sidetracked. Driven in-process with every external
# edge stubbed, so the assertion is about the SEND BOUNDARY, not about Jev or cmux.


def _load_turn_classify(tmp_path, monkeypatch):
    """Import turn-classify.py with HOME redirected to a throwaway dir.

    HOME is read at import time, so it must be set before exec_module. The unique
    synthetic module name keeps each test's import independent.
    """
    monkeypatch.setenv("HOME", str(tmp_path))
    spec = importlib.util.spec_from_file_location("turn_classify_under_test", TURN_CLASSIFY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _drive_turn_classify(mod, tmp_path, monkeypatch, *, jev_choice, guard_ok):
    """Run one dry-run pass over a single lane whose end-of-turn verdict is `jev_choice`."""
    transcript = tmp_path / "session.jsonl"
    transcript.write_text(
        json.dumps({
            "cwd": "/tmp/nowhere",                 # not under /.worktrees/ -> no nested census
            "role": "assistant",
            "message": {"content": [{"type": "text", "text": "I finished the work."}]},
        }) + "\n",
        encoding="utf-8",
    )
    calls = {"send": [], "guard": []}

    monkeypatch.setattr(mod, "lanes_with_open_question", lambda: (set(), True))
    monkeypatch.setattr(mod, "registry", lambda: [
        {"lane": "L1", "ws": "WS1", "issue_label": ""}])
    monkeypatch.setattr(mod, "sh", lambda argv, timeout=120: (0, json.dumps([{
        "lane": "L1", "ws": "WS1", "sid": "sid-1",
        "size": transcript.stat().st_size, "file": str(transcript),
        "verdict": "STOPPED", "child": None,
    }])))
    monkeypatch.setattr(mod, "jev_choice",
                        lambda state: (jev_choice, {"confidence": 0.9, "cost_usd": 0}))

    def _guard(ws, lane):
        calls["guard"].append((ws, lane))
        return guard_ok, "synthetic guard result"

    def _send(lane, ws, msg, f, before_size, dry):
        calls["send"].append((lane, ws))
        return "WOULD-TEST"

    monkeypatch.setattr(mod, "consumable_now", _guard)
    monkeypatch.setattr(mod, "send", _send)
    rc = mod.main(["--dry-run"])
    return rc, calls


def test_jev_door_withholds_idle_nudge_when_the_guard_refuses(tmp_path, monkeypatch):
    """PRE-FIX this fails: the Jev door sent idle_next_work with no guard.

    With the guard refusing, the fixed code must (a) HAVE CALLED the guard for this
    lane and (b) NOT have sent. Pre-fix, `send` is reached and the guard is never
    consulted — both assertions fail.
    """
    mod = _load_turn_classify(tmp_path, monkeypatch)
    rc, calls = _drive_turn_classify(
        mod, tmp_path, monkeypatch,
        jev_choice="finished_the_work", guard_ok=False,
    )
    assert rc == 0
    assert calls["guard"] == [("WS1", "L1")], (
        "the `finished_the_work` door must re-verify idleness at the send boundary"
    )
    assert calls["send"] == [], (
        "a lane the guard will not certify must NOT receive idle_next_work"
    )


def test_jev_door_sends_idle_nudge_when_the_guard_certifies(tmp_path, monkeypatch):
    """The guard must not over-withhold: a CONSUMABLE lane still gets the nudge."""
    mod = _load_turn_classify(tmp_path, monkeypatch)
    rc, calls = _drive_turn_classify(
        mod, tmp_path, monkeypatch,
        jev_choice="finished_the_work", guard_ok=True,
    )
    assert rc == 0
    assert calls["guard"] == [("WS1", "L1")]
    assert calls["send"] == [("L1", "WS1")], "a consumable lane must still be nudged"


def test_non_idle_kind_is_not_reverified_at_the_send_boundary(tmp_path, monkeypatch):
    """Only `idle_next_work` asserts idleness — every other kind is an ordinary queue.

    This is the over-fix guard: adding the boundary check to a non-idle nudge would
    suppress legitimate continuations.
    """
    mod = _load_turn_classify(tmp_path, monkeypatch)
    rc, calls = _drive_turn_classify(
        mod, tmp_path, monkeypatch,
        jev_choice="asked_the_owner", guard_ok=False,
    )
    assert rc == 0
    assert calls["guard"] == [], "only idle_next_work is re-verified at the boundary"
    assert calls["send"] == [("L1", "WS1")], "a question nudge must still be delivered"


# ── P1 (review @4304fef): the farmed heartbeat-loop derives HOME/PATH ─────────


def test_heartbeat_loop_has_no_hard_pinned_home():
    """PRE-FIX this fails: HOME and both PATH pins named the author's home literally.

    A farmed box then ran `cd "$HOME" || exit 0` against a home it does not have:
    the loop printed nothing, logged nothing, and reported success.
    """
    src = LOOP.read_text(encoding="utf-8")
    assert "/Users/" not in src, (
        "a hard-pinned user home survives in the farmed heartbeat loop"
    )
    assert 'export PI_FLEET_HOME="${PI_FLEET_HOME:-$HOME}"' in src, (
        "HOME must be derived from the environment, not hard-pinned"
    )
    assert 'export HOME="$PI_FLEET_HOME"' in src, "HOME must follow PI_FLEET_HOME"
    assert '"$HOME/bin' in src, "the PATH pin must be derived from HOME"


def test_heartbeat_loop_derivation_behaves(tmp_path):
    """Behavioural proof: the actual assignment lines honour PI_FLEET_HOME.

    The lines are extracted and run under a controlled environment, so the test proves
    the derivation rather than the text. PRE-FIX the literal HOME wins and this fails.
    """
    src = LOOP.read_text(encoding="utf-8")
    assigns = [ln for ln in src.splitlines()
               if re.match(r'^export (HOME|PATH|PI_FLEET_HOME|PI_FLEET_PATH_PINNED)=', ln)]
    assert assigns, "no HOME/PATH assignments found in heartbeat-loop.sh"
    script = "\n".join(assigns) + '\nprintf "%s\\n" "$HOME"\nprintf "%s\\n" "$PATH"\n'
    env = dict(os.environ, HOME="/original-home", PI_FLEET_HOME="/fleet-home",
               PATH="/usr/bin:/bin")
    proc = subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True, env=env)
    assert proc.returncode == 0, proc.stderr
    home, path = proc.stdout.splitlines()[:2]
    assert home == "/fleet-home", f"PI_FLEET_HOME was ignored: HOME={home!r}"
    assert path.startswith("/fleet-home/bin:"), path
    assert "/fleet-home/.pi/agent/shims" in path, path
    assert "/original-home" not in path, path


# ── P2 (review @4304fef): lane-guard's --budget must bound the probe ──────────


def _guard_fixture(tmp_path, monkeypatch):
    """Load lane-guard.py with a fake lane-status module and a DETERMINISTIC clock.

    `read_screen`/`ui_working` each advance the fake clock, so the budget's effect is
    exact rather than a timing race.
    """
    spec = importlib.util.spec_from_file_location("lane_guard_under_test", LANE_GUARD)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    session = tmp_path / "sess.jsonl"
    session.write_text("{}\n", encoding="utf-8")
    old = time.time() - 1000
    os.utime(session, (old, old))

    class Clock:
        def __init__(self):
            self.t = time.time()

        def time(self):
            return self.t

        def advance(self, s):
            self.t += s

        def sleep(self, s):
            self.t += s

    clock = Clock()

    class FakeLS:
        def __init__(self):
            self.reads = 0

        def resolve_session(self, ws):
            return "sid-1"

        def session_file(self, sid):
            return str(session)

        def read_screen(self, ws, lines=80):
            self.reads += 1
            clock.advance(0.25)
            return "pane text, no spinner"

        def ui_working(self, ws):          # kept so the PRE-FIX path (which calls it) runs
            self.reads += 1
            clock.advance(0.25)
            return False

        def declared_children(self, label):
            return []

        def parse_child_lines(self, screen):
            return []

        def pending_child(self, path):
            return None

    fake = FakeLS()
    monkeypatch.setattr(mod, "_load_lane_status", lambda: fake)
    monkeypatch.setattr(mod, "time", clock)
    return mod, fake


def test_lane_guard_budget_bounds_the_probe(tmp_path, monkeypatch):
    """PRE-FIX this fails: `over()` was consulted once, before any cmux call.

    Each pane read costs 0.25s of fake time against a 0.2s budget, so by the re-verify
    read the budget is spent. The fixed probe must REFUSE (unknown is not idle); the
    pre-fix probe ran the read anyway and returned CONSUMABLE.
    """
    mod, _fake = _guard_fixture(tmp_path, monkeypatch)
    obs = mod.probe("WS1", "L1", 0.0, 0.0, 0.2)
    assert obs["ok"] is False, f"the budget must bound the probe, not just pre-flight it: {obs}"
    assert "budget" in obs["reason"], obs["reason"]


def test_lane_guard_uses_one_pane_read_per_side(tmp_path, monkeypatch):
    """PRE-FIX this fails: each side cost read_screen + ui_working = 2 cmux calls.

    The spinner test reuses the text of the read it already has (14 lines is a superset
    of the 12 `ui_working` reads), so the probe is two pane reads, not four.
    """
    mod, fake = _guard_fixture(tmp_path, monkeypatch)
    obs = mod.probe("WS1", "L1", 0.0, 0.0, 100.0)
    assert obs["ok"] is True, obs
    assert fake.reads == 2, (
        f"expected one pane read per side (2 total), got {fake.reads}"
    )


# ── P2 (review @4304fef): the registry must not advertise a dead bound ───────


def test_registry_does_not_advertise_a_dead_idle_min():
    """PRE-FIX this fails: `IDLE_MIN=9` existed and was registered.

    No code path read it — the WEAK stall set is a hardcoded set of verdict NAMES and
    the CAPACITY field is computed from CAP_IDLE_MIN — so the registry note asserted
    enforcement that did not exist. It was deleted, not wired.
    """
    sh_src = HEARTBEAT.read_text(encoding="utf-8")
    assert not re.search(r"^\s*IDLE_MIN\s*=", sh_src, re.M), (
        "a dead IDLE_MIN constant is back in orchestrator-heartbeat.sh"
    )
    ts_src = REGISTRY_TS.read_text(encoding="utf-8")
    assert 'name: "IDLE_MIN"' not in ts_src, (
        "the stall registry advertises IDLE_MIN, which no code reads"
    )
    assert 'name: "CAP_IDLE_MIN"' in ts_src, "CAP_IDLE_MIN must stay registered"


# ── P1 (review @a2ae413c): lane-triage's pane read must not fail open ─────────
#
# `pane_spinning` is the ONLY pane override on the DONE_READY path, and the caller passes a
# lane through as free capacity on a definite `False` alone. `run()` never inspects the
# return code, so a cmux that exited non-zero with empty stdout came back as `False` --
# a CMUX outage then advertised a BUSY lane as free. Driven in-process against a stubbed `run`.


class _FakeProc:
    def __init__(self, stdout="", returncode=0):
        self.stdout = stdout
        self.returncode = returncode


def _load_lane_triage():
    spec = importlib.util.spec_from_file_location("lane_triage_under_test", LANE_TRIAGE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_pane_spinning_reads_a_failed_read_as_unknown(monkeypatch):
    """PRE-FIX this fails: a failed read returned False == a definite "not spinning".

    A CMUX OUTAGE ADVERTISED A BUSY LANE AS FREE. Absence of a signal is not evidence of
    absence — only a definite False (pane read, no spinner) may pass a lane through.
    """
    mod = _load_lane_triage()
    monkeypatch.setattr(mod, "run", lambda *a, **k: _FakeProc(stdout="", returncode=1))
    assert mod.pane_spinning("WS1") is None, "a failed read is UNKNOWN, not 'not spinning'"


def test_pane_spinning_reads_an_empty_pane_as_unknown(monkeypatch):
    """rc=0 with an empty pane is still not a pane read."""
    mod = _load_lane_triage()
    monkeypatch.setattr(mod, "run", lambda *a, **k: _FakeProc(stdout="   \n", returncode=0))
    assert mod.pane_spinning("WS1") is None


def test_pane_spinning_unknown_ws_is_unknown(monkeypatch):
    """PRE-FIX this fails: a missing workspace (registry gap) was a definite False."""
    mod = _load_lane_triage()
    assert mod.pane_spinning(None) is None
    assert mod.pane_spinning("") is None


def test_pane_spinning_still_distinguishes_spinner_from_idle(monkeypatch):
    """The over-fix guard: an idle pane must still pass through as a definite False.

    Returning None unconditionally would withhold every DONE_READY lane and the capacity
    signal would go silent; a live spinner must still read True.
    """
    mod = _load_lane_triage()
    monkeypatch.setattr(mod, "run", lambda *a, **k: _FakeProc(stdout="Working… esc to interrupt"))
    assert mod.pane_spinning("WS1") is True
    monkeypatch.setattr(mod, "run", lambda *a, **k: _FakeProc(stdout="user@host repo %\n"))
    assert mod.pane_spinning("WS1") is False


# ── P2 (review @a2ae413c): lane-guard loads the classifier from its committed home ──


def test_lane_guard_loads_the_classifier_from_its_committed_location():
    """PRE-FIX this fails: `_load_lane_status` only ever looked at its sibling.

    The committed layout is `scripts/lane-status.py` + `scripts/lane/lane-guard.py`, so from a
    checkout the module load raised FileNotFoundError and `safe-send.sh` -- which reaches the
    guard by sibling path -- refused EVERY send. Mirrors lane-wip.py's repo-root fallback.
    """
    spec = importlib.util.spec_from_file_location("lane_guard_load_under_test", LANE_GUARD)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    ls = mod._load_lane_status()
    for name in ("resolve_session", "session_file", "read_screen", "ui_working",
                 "declared_children", "parse_child_lines", "pending_child"):
        assert callable(getattr(ls, name, None)), f"lane-status.py is missing {name}"


def test_lane_guard_refuses_when_the_reverify_read_is_unreadable(tmp_path, monkeypatch):
    """PRE-FIX this fails: the step-6 read's `""` was read as "nothing appeared".

    `read_screen` returns "" on any cmux failure, and "" contains no spinner and parses no
    child lines — so the one branch whose job is to catch a turn that BEGINS during the probe
    certified CONSUMABLE without the evidence it declares.
    """
    mod, fake = _guard_fixture(tmp_path, monkeypatch)
    real = fake.read_screen
    calls = {"n": 0}

    def flaky(ws, lines=80):
        calls["n"] += 1
        if calls["n"] >= 2:
            return ""                      # the re-verify read fails
        return real(ws, lines)

    monkeypatch.setattr(fake, "read_screen", flaky)
    obs = mod.probe("WS1", "L1", 0.0, 0.0, 100.0)
    assert calls["n"] == 2, f"expected the re-verify read to run: {calls}"
    assert obs["ok"] is False, f"an unreadable re-verify read must not certify CONSUMABLE: {obs}"
    assert "UNREADABLE" in obs["reason"], obs["reason"]
