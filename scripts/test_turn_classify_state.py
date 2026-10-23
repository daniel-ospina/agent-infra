"""The objective cache must not be obeyed as if it were current.

Regression guard for the 2026-10-06 failure: a brief ordered the fleet to stop draining on
`main=RED@c502a32b9` from a reading whose failed attempt had since been superseded by a
successful re-run, and nothing in the text disclosed the reading's age.
"""
import importlib.util, json, os, tempfile, time
from datetime import datetime, timedelta, timezone

SPEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "turn-classify.py")
_spec = importlib.util.spec_from_file_location("turn_classify", SPEC)
tc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tc)

FIX_MAIN = ("OBJECTIVE VERDICT=FIX-MAIN main=RED@c502a32b9 open=14 drafts=3 nondraft=11 "
           "blocked=11 ci_crit_med=37.6m ci_crit_max=37.6m(test (i))")
GREEN = ("OBJECTIVE VERDICT=ADVANCING main=GREEN@8cede9c7bb open=15 drafts=3 nondraft=12 "
         "blocked=12 ci_crit_med=14.9m")


def _cache(line, age_s):
    fd, path = tempfile.mkstemp(prefix="obj-cache-", suffix=".last")
    ts = (datetime.now(timezone.utc) - timedelta(seconds=age_s)).isoformat()
    with os.fdopen(fd, "w") as fh:
        fh.write(ts + "\n" + line + "\n")
    return path


def test_age_is_disclosed():
    p = _cache(GREEN, 30)
    tc.OBJECTIVE_CACHE = p
    out = tc.objective_line()
    assert "state_age=" in out, out
    assert "state_age=0m" in out, out          # 30s -> 0m, and the token must be present
    os.unlink(p)


def test_fresh_blocked_still_issues_the_override():
    """A CURRENT red must keep its teeth: this is the guard that prevents split-brain."""
    p = _cache(FIX_MAIN, 10)
    tc.OBJECTIVE_CACHE = p
    d = tc.main_red_directive()
    assert "MAIN IS RED" in d and "OVERRIDES YOUR NORMAL NEXT STEP" in d, d
    assert "RE-VERIFY" not in d, d
    os.unlink(p)


def test_stale_blocked_must_not_command_the_fleet():
    """THE FIX: an old reading may not park the fleet. It must ask for re-verification."""
    p = _cache(FIX_MAIN, 2400)                   # 40 minutes: older than the serve window
    tc.OBJECTIVE_CACHE = p
    d = tc.main_red_directive()
    assert "RE-VERIFY" in d, d
    assert "OVERRIDES YOUR NORMAL NEXT STEP" not in d, d
    assert "40m" in d, d
    os.unlink(p)


def test_boundary_is_the_window_not_a_hunch():
    p = _cache(FIX_MAIN, tc.OBJECTIVE_FRESH_S - 30)
    tc.OBJECTIVE_CACHE = p
    assert "OVERRIDES" in tc.main_red_directive()
    os.unlink(p)
    p = _cache(FIX_MAIN, tc.OBJECTIVE_FRESH_S + 30)
    tc.OBJECTIVE_CACHE = p
    assert "RE-VERIFY" in tc.main_red_directive()
    os.unlink(p)


def test_unreadable_cache_is_silent_not_wrong():
    tc.OBJECTIVE_CACHE = "/tmp/does-not-exist-%d.last" % int(time.time())
    assert tc.objective_line() == ""
    assert tc.main_red_directive() == ""


# ── EVERY VERDICT IS CLASSIFIED, AND "BUSY" IS NOT A BLACKLIST (#1867 re-review) ──────────────
# ⛔ THE DEFECT THESE LEGS EXIST FOR. The busy guard in `main()` was a bare tuple
# `("WORKING", "LONG-TOOL")`, so any verdict it did not name fell through to the Jev classifier and
# -- at confidence >= MIN_CONFIDENCE -- to `send()`: a CONTINUE message. `lane-status.py` minted
# `UNATTRIBUTED-WORKING` for exactly the lane that must never be messaged (proven CPU progress in
# the lane's own directory, with a session binding nobody can attribute), and nothing here named
# it. The label's stated property, "reported, never dispatched", was false of this consumer.

_LS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lane-status.py")


def _lane_status():
    spec = importlib.util.spec_from_file_location("lane_status_for_partition", _LS_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _classify_one(monkeypatch, tmp_path, verdict):
    """Drive `main()` over ONE lane whose verdict is `verdict`; report what it chose to do.

    Everything the pass touches is stubbed EXCEPT the verdict gate under test: the registry, the
    `lane-status --json` sample, the question scan, the marker store and the two actions
    (`jev_choice` / `send`). `calls["jev"] == 1` therefore means "this lane reached the
    turn-intent classifier", which is the gate that precedes a message.
    """
    sess = tmp_path / "session.jsonl"
    size = sess.write_text(json.dumps({"message": {"role": "assistant",
                                                    "content": [{"type": "text",
                                                                 "text": "I finished the "
                                                                         "refactor."}]}}) + "\n")
    monkeypatch.setattr(tc, "KILL", str(tmp_path / "TURN-CLASSIFY-OFF-does-not-exist"))
    monkeypatch.setattr(tc, "log", lambda *a, **k: None)
    monkeypatch.setattr(tc, "lanes_with_open_question", lambda: (set(), True))
    monkeypatch.setattr(tc, "registry", lambda: [{"lane": "L1", "ws": "WS1", "issue_label": ""}])
    monkeypatch.setattr(tc, "sh", lambda argv, timeout=120: (0, json.dumps([{
        "lane": "L1", "ws": "WS1", "sid": "abc123", "size": size,
        "verdict": verdict, "file": str(sess), "child": None}])))
    monkeypatch.setattr(tc, "lane_cwd", lambda f: None)
    monkeypatch.setattr(tc, "read_marker", lambda lane: {})
    monkeypatch.setattr(tc, "write_marker", lambda lane, **kw: None)
    monkeypatch.setattr(tc, "consumable_now", lambda ws, lane: (True, "ok"))
    calls = {"jev": 0, "send": 0}

    def _jev(state):
        calls["jev"] += 1
        return None, {}                     # unreadable -> fail closed, AFTER the call is counted

    def _send(*a, **k):
        calls["send"] += 1
        return "WOULD-SEND"

    monkeypatch.setattr(tc, "jev_choice", _jev)
    monkeypatch.setattr(tc, "send", _send)
    assert tc.main(["--dry-run", "--lane", "L1"]) == 0
    return calls


def test_a_lane_proven_to_be_working_is_never_handed_to_the_classifier(monkeypatch, tmp_path):
    """⛔ THE FALSIFIED PROPERTY. `UNATTRIBUTED-WORKING` is proven CPU progress in the lane's own
    directory; whatever pid burned it, the lane is NOT stopped, so there is nothing to classify and
    nothing to say. Pre-fix this lane reached `jev_choice` (calls["jev"] == 1)."""
    calls = _classify_one(monkeypatch, tmp_path, "UNATTRIBUTED-WORKING")
    assert calls["jev"] == 0, (
        "a lane whose directory is demonstrably consuming CPU was handed to the turn-intent "
        "classifier -- at confidence >= MIN_CONFIDENCE that is a CONTINUE message into live work")
    assert calls["send"] == 0


def test_the_classifier_gate_still_lets_a_stopped_lane_through(monkeypatch, tmp_path):
    """CONTROL for the leg above, and the reason it is not vacuous: the same harness, the same
    ONE lane, only the verdict differs. A verdict that means "the lane has stopped" must still reach
    the classifier -- otherwise `calls["jev"] == 0` above would prove nothing but a broken fixture."""
    assert _classify_one(monkeypatch, tmp_path, "WEDGED")["jev"] == 1
    # ...and the pre-existing busy member keeps its behaviour, so the set did not replace it.
    assert _classify_one(monkeypatch, tmp_path, "WORKING")["jev"] == 0


def test_every_busy_member_is_wired_to_the_gate(monkeypatch, tmp_path):
    """Asserting over the CONSTANT, not over two literals: a member added to `BUSY_VERDICTS` that the
    gate never consults would be a set that documents a rule the code does not apply."""
    for v in tc.BUSY_VERDICTS:
        assert _classify_one(monkeypatch, tmp_path, v)["jev"] == 0, v


def test_every_published_verdict_is_classified():
    """⛔ THE CLOSURE, NOT THE ONE-LINE FIX. Adding the missing verdict fixes today's fail-open; this
    test is what stops the NEXT verdict from arriving as "not busy" by default. The busy and proceeds
    sets must PARTITION the verdicts `lane-status.py` can publish, and that set is its own canonical
    `PUBLISHED_VERDICTS` (derived from the human table's sort order), so a new verdict cannot be
    minted without appearing here."""
    lane_status = _lane_status()
    busy, proceeds = set(tc.BUSY_VERDICTS), set(tc.PROCEEDS_VERDICTS)
    assert busy.isdisjoint(proceeds), "a verdict cannot both stop and proceed: %s" % (busy & proceeds)
    unclassified = set(lane_status.PUBLISHED_VERDICTS) - (busy | proceeds)
    assert not unclassified, (
        "verdict(s) %s are published by lane-status but classified by neither BUSY_VERDICTS nor "
        "PROCEEDS_VERDICTS -- an unlisted verdict takes the gate's default branch, which is how "
        "UNATTRIBUTED-WORKING became messageable" % sorted(unclassified))
    stale = (busy | proceeds) - set(lane_status.PUBLISHED_VERDICTS)
    assert not stale, "classified here but never published by lane-status: %s" % sorted(stale)
