"""The objective cache must not be obeyed as if it were current.

Regression guard for the 2026-10-06 failure: a brief ordered the fleet to stop draining on
`main=RED@c502a32b9` from a reading whose failed attempt had since been superseded by a
successful re-run, and nothing in the text disclosed the reading's age.
"""
import importlib.util, os, tempfile, time
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
