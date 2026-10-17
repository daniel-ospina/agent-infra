#!/usr/bin/env python3
"""Proof, in BOTH directions, that `pr-loop.py` never dispatches from a BLIND queue (#1918).

WHY THIS FILE EXISTS. `objective.queue()` returns a full set of classes even when the
merge-state read was blind (`mergeStateStatus` reads UNKNOWN while GitHub recomputes). The
beat reports that queue with a qualification -- `queue_read=BLIND(...) -- the DO: counts are
NOT a clearance` + `mergeable_state_unknown=N` -- and `pr-loop.py` consumed the SAME object
while checking neither token: its guard only fires when `classes` is `None` (a per-PR
CHECK-RUN read failure), which a blind merge-state read does not produce. So a classification
built on a state GitHub never reported became lane actions with no caveat at all. The beat
PRINTS; this file acts, and its own rule is "a miss must never become an action".

The rule these tests pin, both ways round:
  * a BLIND queue dispatches nothing -- no `ACT`/`DRY` line, no lane record -- while still
    logging the counts (the counts are real; only the classification is not), and
  * a READABLE queue dispatches exactly as before, unchanged, and
  * the hold is keyed on `objective._queue_read_is_blind`, the beat's OWN predicate: it is not
    a second definition of "blind" that could drift away from the report's threshold.

Run:  <venv>/bin/python -m pytest test_pr_loop.py -q
"""
from __future__ import annotations

import importlib.util
import json
import pathlib
import types

_HERE = pathlib.Path(__file__).resolve().parent


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, _HERE / filename)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


objective = _load("objective_under_test", "objective.py")
pl = _load("pr_loop_under_test", "pr-loop.py")


def _queue(unknown: int, nondraft: int) -> dict:
    """A queue object shaped exactly as `objective.queue()` returns it."""
    by_class = {"call-rail": [[903, ""]],
                "fix-ci": [[901, "python-ci-gate"], [902, "docs"]]}
    return {"open": nondraft, "drafts": 0, "nondraft": nondraft, "dirty": 0, "unstable": 0,
            "unknown": unknown,
            "classes": {"call-rail": 1, "fix-ci": 2},
            "by_class": by_class, "surface": []}


def _run(monkeypatch, tmp_path, q: dict, argv=("--act",), predicate=None) -> str:
    """One pass of `pr-loop.main()` against `q`, with no fleet and no real state file.

    Returns the lane-ledger path. `predicate` overrides the stub objective's
    `_queue_read_is_blind`; it defaults to the REAL one from `objective.py`.
    """
    state = tmp_path / "state"
    state.mkdir()
    monkeypatch.setattr(pl, "STATE", str(state))
    monkeypatch.setattr(pl, "LANES_FILE", str(state / "pr-loop-lanes.json"))
    monkeypatch.setattr(pl, "LOG_FILE", str(state / "pr-loop.log"))
    # No cmux here: an absent workspace releases the slot in `main()`. That is a separate
    # concern (#1918 is about the INPUT, not about lane liveness), so it is stubbed flat.
    monkeypatch.setattr(pl, "lane_live", lambda lane: False)

    fake = types.ModuleType("objective_stub")
    fake.CLASS_ORDER = objective.CLASS_ORDER
    fake.resources = lambda: {"load": 0.0}
    fake.res_action = lambda r: "dispatch-many"
    fake.queue = lambda: q
    # THE REAL PREDICATE, borrowed from objective.py -- never a re-implementation.
    fake._queue_read_is_blind = predicate or objective._queue_read_is_blind
    monkeypatch.setattr(pl, "_objective", lambda: fake)
    monkeypatch.setattr("sys.argv", ["pr-loop.py", *argv])

    assert pl.main() == 0
    return pl.LANES_FILE


def _blind(q: dict) -> bool:
    """The beat's predicate, called the way `build()` calls it: `(unknown, nondraft)`.

    The signature is `objective.py`'s, NOT this file's convenience: `queue_read_is_blind` takes
    the two numbers the report already has, so every call site here would fail loudly if the
    threshold moved to a different shape.
    """
    return objective._queue_read_is_blind(q["unknown"], q["nondraft"])


def _out(capsys) -> str:
    return capsys.readouterr().out


# ── 1. A BLIND QUEUE DISPATCHES NOTHING ──────────────────────────────────────────────────

def test_a_blind_queue_dispatches_nothing(monkeypatch, tmp_path, capsys):
    """8 of 10 non-draft PRs unread = blind (the beat's threshold is >= half).

    BEFORE the fix this pass wrote three lane records (`prloop-903`, `prloop-901`, `prloop-902`)
    and printed three ACT lines -- byte-identical to the readable case below -- with no mention
    that the classification came from a state GitHub never reported.
    """
    q = _queue(unknown=8, nondraft=10)
    assert _blind(q)          # the fixture really is blind
    lanes_file = _run(monkeypatch, tmp_path, q)
    out = _out(capsys)

    assert "ACT " not in out and "DRY " not in out, out
    assert "lane=prloop-" not in out, out
    assert json.load(open(lanes_file)) == {}, "a blind queue must leave no lane record"


def test_a_blind_queue_still_logs_the_counts_and_names_the_blindness(monkeypatch, tmp_path,
                                                                     capsys):
    """The counts are REAL even when the classification is not.

    Silence would be its own dishonesty: `nondraft=` must still be printed, and the reason for
    holding must name the blindness in the beat's own vocabulary -- so an operator reading the
    log can tell "nothing to do" apart from "I could not see".
    """
    q = _queue(unknown=8, nondraft=10)
    _run(monkeypatch, tmp_path, q)
    out = _out(capsys)

    assert "nondraft=10" in out, out
    assert "queue_read=BLIND(8/10" in out, out
    assert "HOLD" in out, out
    assert "NOT a clearance" in out, out


# ── 2. A READABLE QUEUE DISPATCHES EXACTLY AS TODAY ──────────────────────────────────────

def test_a_readable_queue_dispatches_exactly_as_before(monkeypatch, tmp_path, capsys):
    """DIRECTION 2 -- the one that keeps the fix honest. Guarding must not stop the dispatcher.

    Same classes, same order, same cap (band=dispatch-many => 3 fix/review lanes): the three
    entries are recorded under the same lane ids, and `rail` does not spend the cap.
    """
    q = _queue(unknown=0, nondraft=3)
    assert not _blind(q)
    lanes_file = _run(monkeypatch, tmp_path, q)
    out = _out(capsys)

    assert "ACT rail #903" in out, out
    assert "ACT fix #901" in out, out
    assert "ACT fix #902" in out, out
    assert "queue_read=BLIND" not in out, out
    ledger = json.load(open(lanes_file))
    assert sorted(ledger) == ["901", "902", "903"]
    assert ledger["903"]["action"] == "rail"
    assert ledger["903"]["lane"] == "prloop-903"
    assert ledger["901"]["action"] == "fix" and ledger["901"]["lane"] == "prloop-901"
    assert ledger["902"]["action"] == "fix" and ledger["902"]["lane"] == "prloop-902"


def test_a_mostly_readable_queue_is_not_held(monkeypatch, tmp_path, capsys):
    """A few stragglers are ordinary (the lazily-computed state is transient), not a blind read.

    4 of 10 unread stays below the beat's majority threshold -- so the hold must not fire and
    the dispatcher keeps working. This is the fail-closed/fail-open boundary, pinned.
    """
    q = _queue(unknown=4, nondraft=10)
    assert not _blind(q)
    _run(monkeypatch, tmp_path, q)
    out = _out(capsys)

    assert "ACT fix #901" in out, out


# ── 3. THE PREDICATE IS THE BEAT'S OWN, NOT A SECOND DEFINITION ──────────────────────────

def test_the_hold_is_keyed_on_the_beats_predicate(monkeypatch, tmp_path, capsys):
    """A private copy of "how blind is blind" would drift from the report's threshold.

    Proved behaviourally: flip the SHARED predicate to False on a queue that is blind by its
    own numbers, and the dispatcher must dispatch again -- i.e. it consults that predicate and
    nothing else. A locally re-implemented heuristic would ignore the flip and keep holding.
    """
    _run(monkeypatch, tmp_path, _queue(unknown=8, nondraft=10),
         predicate=lambda *_nums: False)
    out = _out(capsys)

    assert "ACT fix #901" in out, out
    assert "queue_read=BLIND" not in out, out


def test_the_predicate_threshold_is_the_beats(monkeypatch, tmp_path):
    """The truth table itself, so the shared definition cannot be quietly re-tuned.

    >= half of the non-draft queue unread is blind; below half is ordinary churn; an unreadable
    queue object is not a claim of blindness (that case is `queue() is None`, held elsewhere).
    """
    assert _blind(_queue(unknown=8, nondraft=10))
    assert _blind(_queue(unknown=5, nondraft=10))
    assert not _blind(_queue(unknown=4, nondraft=10))
    assert not _blind(_queue(unknown=0, nondraft=10))
    # An EMPTY queue cannot be blind (no PR to be unread): 0 of 0 unread is a READABLE empty
    # queue, and `max(1, 0)` is what keeps the comparison from reading 0 >= 0 as blind.
    assert not objective._queue_read_is_blind(0, 0)


def test_the_beat_and_the_dispatcher_read_the_same_function():
    """Both consumers must resolve "blind" to the SAME object, in this repo's source.

    The behaviour test above shows `pr-loop` consults the predicate; this one shows the beat
    does too -- i.e. there is exactly one definition, and it is the one both read.
    """
    src = (_HERE / "objective.py").read_text()
    body = src.split("def build(", 1)[1]
    # The beat passes the two numbers it already has -- the same `(unknown, nondraft)` shape
    # `pr-loop.py` calls, so the two sites cannot drift into different thresholders.
    assert '_queue_read_is_blind(_u, q["nondraft"])' in body
    # The old inline expression must be gone; if it came back, there would be two definitions.
    assert "2 * _u >=" not in body
    # ...and the expression itself must live in exactly ONE place in the module.
    assert src.count("2 * unknown >=") == 1
    # The DISPATCHER calls the same function, with the same arity, on the queue it acts from.
    loop_src = (_HERE / "pr-loop.py").read_text()
    assert '_queue_read_is_blind(_unknown, q["nondraft"])' in loop_src
    # And no second threshold lives in `pr-loop.py`.
    assert "2 * " not in loop_src, "a second definition of \"blind\" appeared in pr-loop.py"
