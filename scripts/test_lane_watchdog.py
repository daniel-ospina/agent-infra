#!/usr/bin/env python3
"""Tests for lane-watchdog — MUTATION tests for the three reaping gates.

This file is a guard rail, not documentation. The watched script signals processes, so every test
here exists to prove a specific way it could kill something it must not:

  * a subtree that is WORKING                 -> never a candidate (gate 1)
  * a parked child with a BUSY grandchild     -> never a candidate (gate 1, subtree not process)
  * a lane's OWN pi                           -> never a candidate (only dispatched offspring)
  * anything under a human terminal           -> refused outright (gate 2)
  * a chain we cannot prove is the fleet's    -> refused outright (gate 2)
  * a young process                           -> not ripe (gate 3)
  * one frozen sample                         -> not ripe; needs ticks (gate 3)
  * no `--apply`                              -> nothing is ever signalled

If a change makes any of these pass for the wrong reason, the change removed a gate.
"""
import importlib.util
import os
import time

import pytest

_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lane-watchdog.py")

# Every realistic table needs the fleet boundary in it, or gate 2 refuses it by default -- which is
# the correct polarity ("an unproven target is reported, never reaped") and these tables honour it.
CMUX = "/Applications/cmux.app/Contents/MacOS/cmux"
BASE = {
    1: dict(ppid=0, stat="Ss", cpu=0.0, cmd="/sbin/launchd"),
    100: dict(ppid=1, stat="Ss", cpu=0.0, cmd=CMUX),
}


@pytest.fixture(scope="module")
def W():
    spec = importlib.util.spec_from_file_location("lane_watchdog_under_test", _PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def T(ppid, cpu=0.0, stat="Ss", cmd="pi"):
    """One `ps` row."""
    return dict(ppid=ppid, stat=stat, cpu=cpu, cmd=cmd)


def test_cpu_seconds_parses_every_ps_shape(W):
    assert W.cpu_seconds("0:09.69") == pytest.approx(9.69)
    assert W.cpu_seconds("1:04:00") == pytest.approx(3840.0)
    assert W.cpu_seconds("02-01:00:00") == pytest.approx(2 * 86400 + 3600.0)
    assert W.cpu_seconds("garbage") == 0.0


# ── GATE 1: zero CPU delta, measured over the whole SUBTREE ───────────────────

def test_a_working_child_is_never_a_candidate(W):
    """The one true positive this must never produce: a child doing work."""
    a = {**BASE, 200: T(100, cpu=10.0), 300: T(200, cpu=5.0)}
    b = {**BASE, 200: T(100, cpu=10.0), 300: T(200, cpu=12.5)}
    assert W.frozen_subtrees(a, b) == [], "a child that burned 7.5s of CPU is WORKING"


def test_a_parked_child_with_a_busy_grandchild_is_not_a_candidate(W):
    """⛔ THE SUBTREE, NOT THE PROCESS. A `pi` wrapper sits at ~0 CPU while its own bash child does
    the work -- judging the process alone would reap a subtree that is demonstrably busy. Measured
    shape 2026-10-12: Drain's pi at `S+`, +7.70 CPU-s/25s, driving a `curl -sS --http1.1 -m 25`."""
    a = {**BASE, 200: T(100, cpu=10.0), 300: T(200, cpu=9.0),
         301: T(300, cpu=1.0, cmd="curl -sS --http1.1 -m 25 ...")}
    b = {**BASE, 200: T(100, cpu=10.0), 300: T(200, cpu=9.0),
         301: T(300, cpu=2.0, cmd="curl -sS --http1.1 -m 25 ...")}
    assert W.frozen_subtrees(a, b) == [], "the grandchild is working -- nothing here is frozen"


def test_a_frozen_child_of_a_pi_parent_is_a_candidate(W):
    """The real positive: three children of the orchestrator, `Ss`, dCPU exactly 0, no transcript."""
    a = {**BASE, 1727: T(100, cpu=50.0), 36186: T(1727, cpu=9.69), 36189: T(1727, cpu=8.10)}
    b = {**BASE, 1727: T(100, cpu=50.7), 36186: T(1727, cpu=9.69), 36189: T(1727, cpu=8.10)}
    got = W.frozen_subtrees(a, b)
    assert {c["pid"] for c in got} == {36186, 36189}
    for c in got:
        assert c["ppid"] == 1727 and c["d_cpu"] == 0.0


def test_a_lane_own_pi_is_never_a_candidate(W):
    """⛔ IT REAPS THE CHILD, NEVER THE LANE. The lane's pi holds the conversation and its context;
    the frozen offspring hold nothing. Killing the parent destroys the work we are trying to save."""
    a = {**BASE, 1727: T(100, cpu=50.0)}
    b = {**BASE, 1727: T(100, cpu=50.0)}
    assert W.frozen_subtrees(a, b) == [], "the lane's own pi must never be a candidate"


def test_a_bash_child_is_not_a_candidate(W):
    """Only dispatched `pi` offspring. A parked `bash` wrapper is not a stuck dispatch."""
    a = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0, cmd="/bin/bash -c x")}
    b = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0, cmd="/bin/bash -c x")}
    assert W.frozen_subtrees(a, b) == []


def test_a_live_tool_call_under_the_child_is_never_a_candidate(W):
    """⛔ THE P0 REVIEW 2 KILLED. The first attempt at this rule rejected children with a SHELL
    descendant -- which does not survive contact with bash: bash `exec`s a SINGLE SIMPLE COMMAND, so
    `bash -c "gh run watch 123"` leaves NO shell in the tree and the poller IS the descendant. All
    four pollers the rule named (gh run watch / npm ci / docker build / sleep 1800) passed it. An
    adversarial review then ran it against the live table and found it flagging ITS OWN SESSION.

    The rule that is actually true of a tool call and false of the measured orphan: a tool call
    always leaves a NON-`pi` process under the child (the command bash exec'd into), while the orphan
    had no descendants at all. So a candidate may only have `pi` under it.

    The shape below is REAL -- measured on this box by the orchestrator: pi -> bash -> uv -> pytest,
    and by the reviewer: a tool shell exec'd into its command.
    """
    # bash exec'd into the poller: NO shell survives, exactly as bash behaves
    a = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0),
         400: T(300, cpu=0.5, cmd="sleep 1800")}
    b = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0),
         400: T(300, cpu=0.5, cmd="sleep 1800")}
    assert W.frozen_subtrees(a, b) == [], "a poller bash exec'd into is NOT a hang"

    # the orchestrator's measured live-work chain: pi -> bash -> uv -> pytest
    a2 = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0),
          400: T(300, cpu=2.0, cmd="/bin/bash -c export PATH=... uv run pytest"),
          401: T(400, cpu=3.0, cmd="uv run pytest"), 402: T(401, cpu=9.0, cmd="pytest")}
    b2 = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0),
          400: T(300, cpu=2.0, cmd="/bin/bash -c export PATH=... uv run pytest"),
          401: T(400, cpu=3.0, cmd="uv run pytest"), 402: T(401, cpu=9.0, cmd="pytest")}
    assert W.frozen_subtrees(a2, b2) == [], "live pytest work is NOT a hang"

    # and a nested `pi` is the ONLY descendant form allowed
    a3 = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0),
          400: T(300, cpu=2.0, cmd="pi")}
    b3 = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0),
          400: T(300, cpu=2.0, cmd="pi")}
    # (400 is itself a pi under a pi, so it is reported as a candidate too -- reaping either
    # removes the subtree, and a vanished target is handled as success.)
    assert 300 in {c["pid"] for c in W.frozen_subtrees(a3, b3)}, \
        "a child whose only descendant is another pi is still a candidate"


def test_the_frozen_bound_exceeds_the_harness_own_stall_bound(W):
    """⛔ The threshold is justified by the harness's own 20-minute bound, so it must EXCEED it.
    At 900s it did not, and the effective floor was lower still (the clock started during MIN_AGE)."""
    assert W.FROZEN_MIN > 1200, "must exceed TASK_STREAM_STALL_MS (1200000ms = 1200s)"
    assert W.MIN_AGE > 0


def test_the_frozen_clock_does_not_start_during_the_min_age_window(W):
    """A young candidate must accrue NOTHING -- otherwise the effective floor is
    MIN_AGE - tick_spacing + FROZEN_MIN instead of MIN_AGE + FROZEN_MIN."""
    table = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)}
    cands = [dict(pid=300, ppid=200, age_s=100, d_cpu=0.0, subtree=[300])]
    _, _, _, ticks = W.evaluate(cands, table, {}, now=1000.0)
    assert ticks.get("300") is None, "a too-young child must not start its clock"
    # and once it is old enough, the clock starts from THAT observation
    cands2 = [dict(pid=300, ppid=200, age_s=99999, d_cpu=0.0, subtree=[300])]
    _, _, _, ticks2 = W.evaluate(cands2, table, ticks, now=2000.0)
    assert ticks2["300"]["first_seen"] == 2000.0


def test_is_pi_does_not_match_an_argument_named_pi(W):
    """`endswith("/pi")` also matched `grep -n foo /pi`."""
    assert W.is_pi(T(1, cmd="pi")) is True
    assert W.is_pi(T(1, cmd="/Users/x/.local/share/pi-node/current/bin/pi")) is True
    assert W.is_pi(T(1, cmd="grep -n foo /pi")) is False
    assert W.is_pi(T(1, cmd="/bin/bash -c x")) is False


def test_the_cpu_tolerance_is_stated_and_tiny(W):
    """The tolerance must be a NAMED constant, because a sub-0.1s twitch has the same signature
    from a parked fork child, a human's prompt redraw, and a timer wake."""
    assert 0 < W.CPU_TOL <= 0.5
    a = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)}
    b = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0 + W.CPU_TOL * 2)}
    assert W.frozen_subtrees(a, b) == [], "above the tolerance is not frozen"


# ── GATE 2: the ancestry walk ────────────────────────────────────────────────

def test_a_human_terminal_ancestor_is_refused_outright(W):
    """⛔ THE GATE THAT MUST NEVER BE WEAKENED. Near-miss 2026-09-17: a parked-CPU rule nearly
    killed the owner's own interactive terminal; only the ancestry walk stopped it. And `ppid 1`
    proves nothing -- a daemonising service reparents to 1 BY DESIGN."""
    table = {1: T(0, cmd="/sbin/launchd"),
             50: T(1, cmd="/Applications/Terminal.app/Contents/MacOS/Terminal"),
             60: T(50, cmd="-zsh"), 70: T(60, cpu=1.0), 80: T(70, cpu=1.0)}
    assert W.human_above(80, table) is True
    assert W.human_above(70, table) is True


def test_an_iterm_ancestor_is_refused(W):
    table = {1: T(0, cmd="/sbin/launchd"),
             50: T(1, cmd="/Applications/iTerm.app/Contents/MacOS/iTerm2"), 70: T(50, cpu=1.0)}
    assert W.human_above(70, table) is True


def test_a_cmux_owned_chain_is_not_a_human_chain(W):
    """⛔ THE FLEET'S OWN CHAIN MUST STAY REAPABLE, or the watchdog can never act on this box.

    Measured ancestry for every lane here: the chain runs through `/usr/bin/login` AND `-/bin/zsh`
    before reaching cmux. So "any login shell in the chain is a human" refuses EVERY lane -- safe,
    and a no-op. The discriminator is the BOUNDARY, not the presence of a marker.
    """
    table = {1: T(0, cmd="/sbin/launchd"), 882: T(1, cmd=CMUX),
             1047: T(882, cmd="/usr/bin/login -flp danielospina /bin/bash --noprofile --norc"),
             1049: T(1047, cmd="-/bin/zsh"), 1727: T(1049, cmd="pi"),
             36186: T(1727, cpu=1.0)}
    assert W.human_above(36186, table) is False, "the fleet's own chain must be reapable"
    assert W.human_above(1727, table) is False


def test_a_human_terminal_below_cmux_still_wins(W):
    """The boundary is walked NEAREST-FIRST, so a human terminal between the process and cmux is
    still refused -- ordering is the mechanism, not the mere presence of a marker."""
    table = {1: T(0, cmd="/sbin/launchd"), 882: T(1, cmd=CMUX),
             900: T(882, cmd="/Applications/Terminal.app/Contents/MacOS/Terminal"),
             910: T(900, cmd="-zsh"), 920: T(910, cpu=1.0)}
    assert W.human_above(920, table) is True


def test_an_unprovable_chain_is_refused(W):
    """⛔ THE DEFAULT IS REFUSE. A chain with neither a human terminal nor cmux is one we cannot
    prove is ours, and an unproven target is reported, never reaped."""
    table = {1: T(0, cmd="/sbin/launchd"), 500: T(1, cmd="/some/daemon"), 510: T(500)}
    assert W.human_above(510, table) is True


def test_a_refused_candidate_is_not_ripe(W, monkeypatch):
    """The gate must STOP the action, not merely annotate it."""
    table = {1: T(0, cmd="/sbin/launchd"),
             50: T(1, cmd="/Applications/Terminal.app/Contents/MacOS/Terminal"),
             60: T(50, cmd="-zsh"), 200: T(60, cpu=1.0), 300: T(200, cpu=1.0)}
    cands = [dict(pid=300, ppid=200, age_s=99999, d_cpu=0.0, subtree=[300])]
    ripe, watching, refused, _ = W.evaluate(cands, table, {}, now=1e9)
    assert ripe == [] and len(refused) == 1
    assert "HUMAN" in refused[0]["reason"]


# ── GATE 3: progress vs its own expected distribution ────────────────────────

def test_a_young_child_is_not_ripe(W):
    table = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)}
    cands = [dict(pid=300, ppid=200, age_s=30, d_cpu=0.0, subtree=[300])]
    ripe, watching, refused, _ = W.evaluate(cands, table, {}, now=1e9)
    assert ripe == [] and refused == [] and len(watching) == 1
    assert "young" in watching[0]["reason"]


def test_one_frozen_sample_is_not_enough(W):
    """⛔ A child in a long model call sits at zero CPU with no transcript growth for MINUTES --
    exactly the frozen signature. One window cannot tell them apart, so it takes ticks."""
    table = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)}
    cands = [dict(pid=300, ppid=200, age_s=99999, d_cpu=0.0, subtree=[300])]
    ripe, _, _, ticks = W.evaluate(cands, table, {}, now=1000.0)
    assert ripe == [], "a first observation must never be ripe"
    assert ticks["300"]["first_seen"] == 1000.0

    ripe, _, _, ticks = W.evaluate(cands, table, ticks, now=1000.0 + W.FROZEN_MIN / 2)
    assert ripe == [], "not enough ticks yet"

    state = {"300": {"first_seen": 1000.0, "ticks": W.FROZEN_TICKS}}
    ripe, _, _, _ = W.evaluate(cands, table, state, now=1000.0 + W.FROZEN_MIN + 1)
    assert len(ripe) == 1 and ripe[0]["pid"] == 300
    assert ripe[0]["frozen_for"] >= W.FROZEN_MIN


# ── the action ───────────────────────────────────────────────────────────────

def test_reap_terminates_the_subtree_children_first(W, monkeypatch):
    """Children before parents, so nothing is reparented mid-kill, and the PARENT is never in the
    signal list."""
    killed = []
    monkeypatch.setattr(W.os, "kill", lambda p, s: killed.append((p, s)))
    table = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0), 301: T(300, cpu=1.0)}
    cand = dict(pid=300, ppid=200, subtree=[300, 301], d_cpu=0.0, age_s=99999)
    res = W.reap(cand, {}, table, 1)
    assert res["ended"] is True
    assert sorted(p for p, _ in killed) == [300, 301]
    assert 200 not in [p for p, _ in killed], "the parent lane's pi must never be signalled"
    assert all(s == W.signal.SIGTERM for _, s in killed)


def test_a_vanished_process_is_not_an_error(W, monkeypatch):
    """A candidate can exit between the sample and the signal; that is success, not failure."""
    def boom(p, s):
        raise ProcessLookupError()
    monkeypatch.setattr(W.os, "kill", boom)
    table = {**BASE, 300: T(200, cpu=1.0)}
    res = W.reap(dict(pid=300, ppid=200, subtree=[300], d_cpu=0.0, age_s=1), {}, table, 1)
    assert res["ended"] is True and res.get("error") is None


def test_dry_run_never_signals(W, monkeypatch, capsys, tmp_path):
    """`--apply` is the only path that signals, and it is off by default: the action is a kill."""
    killed = []
    monkeypatch.setattr(W.os, "kill", lambda p, s: killed.append(p))
    monkeypatch.setattr(W, "STATE", str(tmp_path / "s.json"))
    monkeypatch.setattr(W, "LOG", str(tmp_path / "l.jsonl"))
    monkeypatch.setattr(W, "LOCK", str(tmp_path / "w.lock"))
    monkeypatch.setattr(W, "ps_table", lambda: {
        **BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)})
    monkeypatch.setattr(W.time, "sleep", lambda s: None)
    monkeypatch.setattr(W, "_age_seconds", lambda pid, table: 99999)
    # ⛔ DRIVE IT ALL THE WAY TO `ripe`, or the test passes vacuously: with an empty state a
    # candidate is only ever "first observation", so `killed == []` would hold even if --apply
    # defaulted to True. This state is exactly what a ripe candidate looks like on the next tick.
    monkeypatch.setattr(W, "STATE", str(tmp_path / "ripe.json"))
    import json as _json
    (tmp_path / "ripe.json").write_text(_json.dumps(
        {"300": {"first_seen": time.time() - W.FROZEN_MIN - 10, "ticks": W.FROZEN_TICKS,
                 "subtree": [300]}}))
    monkeypatch.setattr(W.sys, "argv", ["lane-watchdog.py", "--json"])
    W.main()
    assert killed == [], "a dry run must never signal, even with a ripe candidate"
    assert '"reaped": []' in capsys.readouterr().out


def test_a_changed_subtree_resets_the_clock(W):
    """⛔ THE FALSE POSITIVE THAT NEARLY SHIPPED. Measured 2026-10-12: a live lane's child read
    'frozen' at CPU 0:03.46 -> 0:03.46 while its bash child ran `sleep 180 && gh run view ...`,
    which is zero-CPU BY CONSTRUCTION. A working subtree hands its descendants new pids each
    iteration, so identical composition across ticks is the thing that is actually dead."""
    table = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0), 301: T(300, cpu=1.0)}
    cands = [dict(pid=300, ppid=200, age_s=99999, d_cpu=0.0, subtree=[300, 301])]
    _, _, _, ticks = W.evaluate(cands, table, {}, now=1000.0)
    assert ticks["300"]["subtree"] == [300, 301]

    # next tick the poll loop has replaced its child with a new pid -> clock resets, never ripe
    cands2 = [dict(pid=300, ppid=200, age_s=99999, d_cpu=0.0, subtree=[300, 302])]
    table2 = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0), 302: T(300, cpu=1.0)}
    state = {"300": dict(ticks["300"], ticks=W.FROZEN_TICKS)}
    ripe, watching, _, ticks2 = W.evaluate(cands2, table2, state, now=1000.0 + W.FROZEN_MIN + 5)
    assert ripe == [], "a subtree whose composition changed is doing something"
    assert any("changed" in w["reason"] for w in watching)
    assert ticks2["300"]["first_seen"] == 1000.0 + W.FROZEN_MIN + 5, "the clock must restart"


def test_a_second_run_cannot_double_count_ticks(W, monkeypatch, tmp_path):
    """⛔ THE LOCK IS A GATE, NOT A NICETY. Two concurrent runs would both read the same state and
    both see the other's `first_seen`, so a candidate could reach FROZEN_TICKS in seconds instead of
    minutes -- collapsing the rule that separates a stuck child from one in a long model call."""
    monkeypatch.setattr(W, "LOCK", str(tmp_path / "w.lock"))
    first = W.acquire_lock()
    assert first is not None, "the first run must acquire"
    assert W.acquire_lock() is None, "a concurrent run must be refused"
    # released, a later run acquires again (a killed run cannot leave the fleet wedged)
    import fcntl
    fcntl.flock(first, fcntl.LOCK_UN)
    assert W.acquire_lock() is not None


def test_a_locked_run_observes_nothing_and_signals_nothing(W, monkeypatch, capsys, tmp_path):
    killed = []
    monkeypatch.setattr(W.os, "kill", lambda p, s: killed.append(p))
    monkeypatch.setattr(W, "LOCK", str(tmp_path / "w.lock"))
    monkeypatch.setattr(W, "STATE", str(tmp_path / "s.json"))
    # ⛔ KEEP THE HANDLE. `main` holds its own for the whole run; a dropped reference closes the fd
    # and silently releases the lock, so a test that discards it proves nothing.
    held = W.acquire_lock()                            # a run is already in progress
    assert held is not None
    monkeypatch.setattr(W.sys, "argv", ["lane-watchdog.py", "--apply", "--json"])
    assert W.main() == 0
    assert killed == []
    assert "another run holds the lock" in capsys.readouterr().out


# ── the liveness gate: an established connection is NOT a hang ─────────────────
# ⛔ Measured by review 2026-10-12: a WORKING `task` child sat exactly on the frozen shape --
# zero descendants, subΔCPU 0.00 -- excluded only by a 0.44s CPU reading. A live provider call HOLDS
# AN ESTABLISHED CONNECTION; the two genuinely-wedged children held none, in every sample.

def test_a_child_holding_an_established_connection_is_never_a_candidate(W, monkeypatch):
    monkeypatch.setattr(W, "has_live_connection", lambda pid: True)
    a = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)}
    b = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)}
    assert W.frozen_subtrees(a, b) == [], "a child in a live model call is NOT a hang"


def test_an_unknown_connection_state_refuses(W, monkeypatch):
    """⛔ UNKNOWN MUST REFUSE. lsof failing/timing out is not evidence of no connection, and this
    gate authorises a kill -- every other unclear read in the file abstains."""
    monkeypatch.setattr(W, "has_live_connection", lambda pid: None)
    a = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)}
    b = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)}
    assert W.frozen_subtrees(a, b) == [], "an unreadable connection state must refuse"


def test_a_child_with_no_connection_is_still_a_candidate(W, monkeypatch):
    """The gate must not make the detector a no-op: the measured orphan held no connection."""
    monkeypatch.setattr(W, "has_live_connection", lambda pid: False)
    a = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)}
    b = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)}
    assert [c["pid"] for c in W.frozen_subtrees(a, b)] == [300]


def test_a_failed_lsof_never_reads_as_no_connection(W, monkeypatch):
    """⛔ THE CALLEE, NOT THE CONSUMER — THIS IS THE READ THAT AUTHORISES THE KILL (2026-10-13).

    `test_an_unknown_connection_state_refuses` proves the CONSUMER's polarity by monkeypatching
    `has_live_connection` ITSELF, so it stayed green while the function returned `False` for an
    lsof that FAILED — and `False` is the only value that puts a child in the reap set. Probe the
    function, not its callers.

    ⛔ THE EXPECTATIONS BELOW ARE MEASURED ON THIS HOST (lsof 4.91), because the first cut of this
    fix inverted them: a dead pid and a live pid with no established TCP BOTH exit **1** with empty
    stdout AND empty stderr, while a genuine failure exits 1 but writes to stderr. A `rc != 0 ->
    None` rule would have made the reaper permanently INERT; a `bool(stdout)` rule made a failed
    read a kill licence. Both are wrong, in opposite directions.
    """
    class R:
        def __init__(self, rc, out="", err=""):
            self.returncode, self.stdout, self.stderr = rc, out, err

    def fake(rc, out="", err=""):
        monkeypatch.setattr(W.subprocess, "run", lambda *a, **k: R(rc, out, err))
        return W.has_live_connection(4242)

    # ── the measured "ran fine, located nothing" shape: silence on both streams at rc=1 ──
    assert fake(1) is False, "lsof rc=1 with no output is the genuine 'no connection'"
    # ── anything that FAILED, however it reports, is UNKNOWN and must refuse ──
    assert fake(1, err="lsof: illegal option character: -\n") is None, "a failing lsof is UNKNOWN"
    assert fake(127) is None, "a missing lsof is UNKNOWN"
    assert fake(-9) is None, "a signalled lsof is UNKNOWN"
    assert fake(0) is None, "rc=0 with NO output is anomalous, not a clean 'no connection'"
    assert fake(2, out="something") is None, "output with a dirty exit is UNKNOWN"
    # a timeout / spawn failure raises, and must also refuse
    def boom(*a, **k):
        raise OSError("timed out")
    monkeypatch.setattr(W.subprocess, "run", boom)
    assert W.has_live_connection(4242) is None
    # ── FALSE-BLOCK CONTROL: the one shape that means a connection is HELD ──
    assert fake(0, out="COMMAND  PID USER FD TYPE\npi 4242 d 12u IPv4 0x1 0t0 TCP a->b:443 (ESTABLISHED)\n") is True


def test_the_connection_probe_still_licenses_a_reap(W, monkeypatch):
    """The other pole. If the probe never returns False the watchdog is an INERT enforcer, so the
    'no connection' path must still reach the reap set through the REAL probe (not a stub)."""
    class R:
        returncode, stdout, stderr = 1, "", ""
    monkeypatch.setattr(W.subprocess, "run", lambda *a, **k: R())
    a = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)}
    b = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)}
    assert [c["pid"] for c in W.frozen_subtrees(a, b)] == [300]


# ── fail-open P2s found by review cycle 3 ────────────────────────────────────

def test_an_unreadable_age_refuses_rather_than_skipping_min_age(W, monkeypatch):
    """⛔ `age_s < min_age` is FALSE when age is None, so MIN_AGE was skipped entirely and the
    candidate ripened at +FROZEN_MIN regardless of how new it was. Verified by probe before the fix:
    age_s=None ripened on the second pass at +1801s."""
    monkeypatch.setattr(W, "has_live_connection", lambda pid: False)
    table = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)}
    cands = [dict(pid=300, ppid=200, age_s=None, d_cpu=0.0, subtree=[300])]
    state = {"300": {"first_seen": 1000.0, "ticks": W.FROZEN_TICKS, "subtree": [300]}}
    ripe, watching, _, _ = W.evaluate(cands, table, state, now=1000.0 + W.FROZEN_MIN + 5)
    assert ripe == [], "an unreadable age must never ripen"
    assert any("age unreadable" in w["reason"] for w in watching)


def test_a_recycled_pid_does_not_inherit_the_dead_process_clock(W, monkeypatch):
    """⛔ The observation is keyed by pid alone. Review measured a 601-second-old process ripening on
    its FIRST observation with `frozen_for: 259200` taken from a three-day-old row for a recycled
    pid. The process birth epoch must match."""
    monkeypatch.setattr(W, "has_live_connection", lambda pid: False)
    table = {**BASE, 200: T(100, cpu=1.0), 300: T(200, cpu=1.0)}
    now = 1_000_000.0
    # `age_s` says this process is 601s old, so its birth epoch is now-601
    cands = [dict(pid=300, ppid=200, age_s=601, d_cpu=0.0, subtree=[300])]
    # ... but the persisted row was written for a process born THREE DAYS ago
    state = {"300": {"first_seen": now - 259200, "ticks": W.FROZEN_TICKS, "subtree": [300],
                     "birth": now - 259200}}
    ripe, watching, _, ticks = W.evaluate(cands, table, state, now=now)
    assert ripe == [], "a recycled pid must not inherit the dead process's clock"
    assert any("recycled" in w["reason"] for w in watching)
    assert ticks["300"]["first_seen"] == now, "the clock must restart at this observation"
    assert ticks["300"]["ticks"] == 1


def test_descendants_terminates_on_a_cycle(W):
    """A ppid cycle made the loop run forever; a hung run holds the flock for the life of the
    process, so every later run exits `skipped` and the guard dies silently."""
    import threading
    table = {1: T(0), 2: T(3), 3: T(2)}          # 2 <-> 3 cycle, rooted at 1 via 2/3 unreachable
    out = {}
    t = threading.Thread(target=lambda: out.update(r=W.descendants(2, table)))
    t.daemon = True
    t.start()
    t.join(timeout=5)
    assert not t.is_alive(), "descendants() must terminate on a cyclic table"
