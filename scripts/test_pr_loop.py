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
  * a queue whose CLASS counts are not a clearance dispatches nothing -- no `ACT`/`DRY` line,
    no lane record -- while still logging the counts (the counts are real; only the
    classification is not), and
  * a READABLE queue dispatches exactly as before, unchanged, and
  * the hold is keyed on `objective._class_counts_are_a_clearance`, the beat's OWN predicate --
    not a second definition that could drift away from the report's threshold, and NOT the
    narrower "is the READ blind" question (a REST pass answers that one YES while its class
    counts are built entirely on an unread merge state; #1942 review A/P2).

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


def _queue(unknown: int, nondraft: int, source: str = "graphql") -> dict:
    """A queue object shaped exactly as `objective.queue()` returns it.

    `source` is `queue()`'s own provenance key: `"graphql"` for the primary read, `"rest"`
    for the fallback that answered the LIST but cannot answer the LAZY merge state (#2138).
    """
    by_class = {"call-rail": [[903, ""]],
                "fix-ci": [[901, "python-ci-gate"], [902, "docs"]]}
    return {"open": nondraft, "drafts": 0, "nondraft": nondraft, "dirty": 0, "unstable": 0,
            "unknown": unknown, "source": source,
            "classes": {"call-rail": 1, "fix-ci": 2},
            "by_class": by_class, "surface": []}


def _run(monkeypatch, tmp_path, q: dict, argv=("--act",), clearance=None) -> str:
    """One pass of `pr-loop.main()` against `q`, with no fleet and no real state file.

    Returns the lane-ledger path. `clearance` overrides the stub objective's
    `_class_counts_are_a_clearance`; it defaults to the REAL one from `objective.py`.
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
    # THE REAL PREDICATES, borrowed from objective.py -- never a re-implementation. BOTH are
    # presented because `pr-loop.main()` consults the CLEARANCE question, and a stub missing it
    # is not "a readable queue": it is an `AttributeError` inside `main()`.
    fake._queue_read_is_blind = objective._queue_read_is_blind
    fake._class_counts_are_a_clearance = (clearance or objective._class_counts_are_a_clearance)
    monkeypatch.setattr(pl, "_objective", lambda: fake)
    monkeypatch.setattr("sys.argv", ["pr-loop.py", *argv])

    assert pl.main() == 0
    return pl.LANES_FILE


def _blind(q: dict) -> bool:
    """The beat's blind predicate, called the way `build()` calls it: `(unknown, nondraft, source)`.

    The signature is `objective.py`'s, NOT this file's convenience: `queue_read_is_blind` takes
    the two numbers the report already has plus the read's provenance, so every call site here
    would fail loudly if the threshold moved to a different shape.
    """
    return objective._queue_read_is_blind(q["unknown"], q["nondraft"],
                                          q.get("source") or "graphql")


def _clearance(q: dict) -> bool:
    """The DISPATCHER's question, same shape: may the CLASS counts be acted on?"""
    return objective._class_counts_are_a_clearance(q["unknown"], q["nondraft"],
                                                   q.get("source") or "graphql")


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
    """A private copy of "may these class counts be acted on" would drift from the report.

    Proved behaviourally: flip the SHARED predicate to True on a queue that is blind by its
    own numbers, and the dispatcher must dispatch again -- i.e. it consults that one function
    and nothing else. A locally re-implemented heuristic would ignore the flip and keep
    holding.
    """
    _run(monkeypatch, tmp_path, _queue(unknown=8, nondraft=10),
         clearance=lambda *_nums: True)
    out = _out(capsys)

    assert "ACT fix #901" in out, out
    assert "queue_read=BLIND" not in out, out


def test_a_rest_sourced_queue_is_held_on_the_shape_queue_returns(monkeypatch, tmp_path,
                                                                 capsys):
    """A REST pass is NOT blind -- and the dispatcher must STILL hold. (#1942 review, A/P2)

    Both halves matter, and the old fixture asserted the wrong one. `objective.py` (#2138)
    reports a REST-sourced queue as `unread`, never as `queue_read=BLIND`, because REST answered
    the list, its length and every row: blindness is a property of the READ, and this read
    answered. But `_rest_pr()` leaves `mergeStateStatus` None for EVERY row, so the real REST
    shape is `unknown == nondraft` -- and the beat's own sentence for that queue is "the CLASS
    counts are NOT a clearance". `pr-loop` acts on the CLASSES, so holding is the dispatcher
    OBEYING the report, not contradicting it.

    The fixture is that real shape (10/10). The earlier revision used 8/10 and asserted
    DISPATCH, i.e. it pinned the fail-open: acting on a classification built on a field GitHub
    never computed, where `classify_pr()`'s DIRTY arm cannot even fire -- so a CONFLICTED PR
    gets a `call-rail`/`fix-ci` brief and `resolve-conflict`, the one brief this file can carry
    out, is unreachable.
    """
    q = _queue(unknown=10, nondraft=10, source="rest")
    assert not _blind(q), "the beat does not call a REST sample BLIND -- that part is #2138"
    assert not _clearance(q), "...and it DOES say the CLASS counts are not a clearance"
    lanes_file = _run(monkeypatch, tmp_path, q)
    out = _out(capsys)

    assert not [ln for ln in out.splitlines() if ln.startswith(("DRY ", "ACT "))], out
    assert "lane=prloop-" not in out, out
    assert json.load(open(lanes_file)) == {}, "a non-clearance queue must leave no lane record"
    # The reason must be the RIGHT one: REST provenance, not the blindness word (#2138 must not
    # be silently re-labelled by this guard), and still the clearance sentence.
    assert "queue_read=BLIND" not in out, out
    assert "queue_read=REST(" in out, out
    assert "NOT a clearance" in out, out
    assert "HOLD" in out, out
    # A REST sample with NOTHING unread is a clearance -- the hold is about the unread field,
    # not about REST as a source in its own right.
    assert _clearance(_queue(unknown=0, nondraft=10, source="rest"))


def test_the_predicate_threshold_is_the_beats(monkeypatch, tmp_path):
    """The truth table itself, so the shared definition cannot be quietly re-tuned.

    >= half of the non-draft queue unread is blind; below half is ordinary churn. The numbers
    are passed positionally -- the beat's own `(unknown, nondraft, source)` shape -- because there
    is no queue object to consult here: `queue() is None` (no readable queue at all) is a
    different case, held by `pr-loop.py`'s first guard.
    """
    assert _blind(_queue(unknown=8, nondraft=10))
    assert _blind(_queue(unknown=5, nondraft=10))
    assert not _blind(_queue(unknown=4, nondraft=10))
    assert not _blind(_queue(unknown=0, nondraft=10))
    # The SAME numbers on a REST-sourced read are NOT blind: the queue was answered, and only
    # the lazy merge state was not (#2138). Blindness is a property of the READ, not the count.
    assert not _blind(_queue(unknown=8, nondraft=10, source="rest"))
    assert not _blind(_queue(unknown=10, nondraft=10, source="rest"))
    # An EMPTY queue cannot be blind (no PR to be unread): 0 of 0 unread is a READABLE empty
    # queue, and `max(1, 0)` is what keeps the comparison from reading 0 >= 0 as blind.
    assert not objective._queue_read_is_blind(0, 0)


def test_the_clearance_question_is_NOT_the_blindness_question(monkeypatch, tmp_path):
    """The two questions and the ONE place they disagree -- pinned, so neither collapses.

    GraphQL: clearance is exactly `not blind` (the dispatcher must not re-threshold).
    REST: the read answered (`blind is False`) while the class counts rest on an unread merge
    state, so clearance is False -- and it is False for the REAL shape (`unknown == nondraft`),
    not only for a hand-picked one.
    """
    # GraphQL -- identical to the blindness answer, both directions.
    assert not _clearance(_queue(unknown=8, nondraft=10))
    assert not _clearance(_queue(unknown=5, nondraft=10))
    assert _clearance(_queue(unknown=4, nondraft=10))
    assert _clearance(_queue(unknown=0, nondraft=10))
    assert _clearance(_queue(unknown=0, nondraft=0))
    # REST -- every row's merge state is unread by construction (`_rest_pr`), so no clearance.
    assert not _clearance(_queue(unknown=10, nondraft=10, source="rest"))
    assert not _clearance(_queue(unknown=8, nondraft=10, source="rest"))
    # ...but "REST" is not a blanket refusal: nothing unread is a clearance from any source.
    assert _clearance(_queue(unknown=0, nondraft=10, source="rest"))
    assert _clearance(_queue(unknown=0, nondraft=0, source="rest"))


def test_the_beat_and_the_dispatcher_read_the_same_function():
    """Both consumers must resolve the SAME question, in this repo's source.

    The behaviour tests above show `pr-loop` consults the shared clearance predicate; this one
    shows the two predicates are one chain, not two opinions: the clearance question DELEGATES
    to the blindness threshold for GraphQL, and the dispatcher calls the clearance question.
    """
    src = (_HERE / "objective.py").read_text()
    body = src.split("def build(", 1)[1]
    # The beat passes the numbers and the provenance it already has -- the same
    # `(unknown, nondraft, source)` shape `pr-loop.py` calls, so the two sites cannot drift into
    # different thresholders.
    assert '_queue_read_is_blind(_u, q["nondraft"], _src)' in body
    # The old inline expression must be gone; if it came back, there would be two definitions.
    assert "2 * _u >=" not in body
    # ...and the expression itself must live in exactly ONE place in the module.
    assert src.count("2 * unknown >=") == 1
    # The CLEARANCE predicate delegates to it, so re-thresholding "blind" still moves the
    # dispatcher (a copy would not).
    clearance_def = src.split("def _class_counts_are_a_clearance(", 1)[1]
    clearance_body = clearance_def.split("\ndef ", 1)[0]
    assert "not _queue_read_is_blind(unknown, nondraft, source)" in clearance_body
    assert "2 * " not in clearance_body, "the clearance predicate grew its own threshold"
    # The DISPATCHER calls the clearance question, with the beat's arity and provenance, on the
    # queue it acts from.
    loop_src = (_HERE / "pr-loop.py").read_text()
    assert '_class_counts_are_a_clearance(_unknown, q["nondraft"], _src)' in loop_src
    assert '_src = q.get("source") or "graphql"' in loop_src
    # ...and it must NOT decide on the blindness question alone: that is the fail-open this
    # review closed (a REST pass is never "blind", so keying on blindness dispatches on a
    # wholly-unread classification).
    assert "_queue_read_is_blind" not in loop_src, (
        "pr-loop.py is deciding on the READ question again -- a REST pass answers that one YES "
        "while its class counts are built on an unread merge state")
    # And no second threshold lives in `pr-loop.py`.
    assert "2 * " not in loop_src, "a second definition of \"blind\" appeared in pr-loop.py"


# ── agent-infra#2922: an unreadable cwd on the LAUNCHD path ────────────────────────────────────
# `pr-loop.py` carries the SAME `_checkout_repo` shim as `objective.py` (deliberately -- one
# derivation, two callers). It therefore carried the SAME defect: `os.getcwd()` was evaluated inside
# the `try` around `subprocess.run`, so a launcher refusing to report the cwd was reported as
# `underivable` -- the remedy for a broken `git`/`bash` -- instead of as the cwd itself. Both files
# are fixed together, so both are pinned together; a fix in one only would leave the beat's other
# reader sending an operator to the wrong remedy.
def test_an_UNREADABLE_CWD_is_named_here_too_not_only_in_objective_py(monkeypatch):
    """Reproduced before the fix: `pl._checkout_repo()` returned `(None, 'underivable')` here."""

    def boom():
        raise FileNotFoundError(2, "No such file or directory")

    monkeypatch.setattr(pl.os, "getcwd", boom)
    assert pl._checkout_repo() == (None, "cwd-unreadable")
    assert pl._checkout_repo("") == (None, "cwd-unreadable")


def test_the_two_shims_agree_on_the_cwd_reason(monkeypatch):
    """One defect, one word: the twin must not answer a THIRD spelling that a reader cannot match."""
    def boom():
        raise PermissionError(1, "Operation not permitted")

    monkeypatch.setattr(pl.os, "getcwd", boom)
    assert pl._checkout_repo()[1] == objective._checkout_repo()[1] == "cwd-unreadable"


def test_the_cwd_refusal_MESSAGE_does_not_advise_the_cwd(monkeypatch):
    """⛔ THE WORD ALONE WAS NOT ENOUGH (review finding, #3000; reproduced before the fix).

    `_checkout_repo()` returning `cwd-unreadable` fixes the ACCESSOR. The one renderer that turns it
    into something an operator reads — `_objective()`'s refusal — branched only on `deriver-missing`
    and funnelled every other cause into the `underivable` text: *"cannot derive this checkout's
    repo from its origin remote ... Run from the checkout you mean, or export OBJECTIVE_REPO=…"*.

    On a launchd box that is the exact wrong remedy #2922 exists to end: the process's cwd is
    PRECISELY what the OS refuses to report, so "run from the checkout you mean" is advice the box
    cannot take, and it sends the operator to debug a `git`/`origin` that is perfectly healthy. The
    twin files had therefore agreed on the reason token while disagreeing on the message — one fact
    reported two ways, which is the failure this resolution is about.

    Reproduced before the fix: with `_checkout_repo` stubbed to `(None, "cwd-unreadable")` and
    `OBJECTIVE_REPO` unset, the message printed was verbatim the `underivable` one.
    """
    monkeypatch.delenv("OBJECTIVE_REPO", raising=False)
    monkeypatch.setattr(pl, "_checkout_repo", lambda *a, **k: (None, "cwd-unreadable"))

    try:
        pl._objective()
    except SystemExit as exc:
        msg = str(exc)
    else:                                                  # pragma: no cover - a refusal must raise
        raise AssertionError("_objective() did not refuse on cwd-unreadable")

    low = msg.lower()
    # it must NAME the working directory as the cause...
    assert "working directory" in low, msg
    # ...and must NOT carry the `underivable` remedy set, which is advice this box cannot take.
    assert "origin remote" not in low, msg
    assert "run from the checkout" not in low, msg
    # it is still a fail-closed refusal that names the fallback it refuses to adopt.
    assert "daniel-ospina/tortoise" in msg, msg
    # ...and it names a remedy that a launchd box can actually perform.
    assert "objective_repo" in low, msg


def test_the_UNREADABLE_refusal_is_not_the_UNDERIVABLE_one(monkeypatch):
    """The two facts stay apart in the MESSAGE too, not only in the accessor's return value.

    A fix that renamed every reason would satisfy this arm's neighbour and destroy this one.
    """
    monkeypatch.delenv("OBJECTIVE_REPO", raising=False)
    monkeypatch.setattr(pl, "_checkout_repo", lambda *a, **k: (None, "underivable"))

    try:
        pl._objective()
    except SystemExit as exc:
        msg = str(exc)
    else:                                                  # pragma: no cover
        raise AssertionError("_objective() did not refuse on underivable")

    assert "origin remote" in msg.lower(), msg
    assert "working directory" not in msg.lower(), msg
