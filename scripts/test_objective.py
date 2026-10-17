#!/usr/bin/env python3
"""Proof, in BOTH directions, that objective.py's blindness flag is honest.

WHY THIS FILE EXISTS. Measured three times on 2026-09-29 the orchestrator's instrument
reported `gh=UNREADABLE` while `gh api rate_limit` reported core 5000/5000 and every REST
read in the fleet succeeded. The cause was a single heavy `gh pr list` (GraphQL, 130+ PRs,
`mergeStateStatus`) hiccuping, plus a flag that could not say WHICH read had failed. A
watchdog that cries wolf is worse than no watchdog: it costs every lane a re-derivation and
teaches the fleet to ignore the token.

The rule these tests pin, both ways round:
  * a GENUINE main/queue TRANSPORT failure still declares the fleet blind, and
  * a HEALTHY read does not, and
  * an OPTIONAL read failing never speaks for the fleet, and
  * an unreadable PAYLOAD (transport fine) is not blindness, and
  * the VERDICT is about the QUEUE: a CI duration is an INDICATOR, and may never decide it
    (owner ruling on #6792 -- "the <10min should be more of a guideline than an absolute
    rule"). That last group is pinned at the bottom of this file.

Run:  <venv>/bin/python -m pytest test_objective.py -q
"""
from __future__ import annotations

import importlib.util
import itertools
import json
import pathlib
import re
import time

import pytest

_SPEC = importlib.util.spec_from_file_location(
    "objective_under_test", pathlib.Path(__file__).with_name("objective.py"))
objective = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(objective)

SHA = "9c4788400" + "b" * 31


class _Result:
    def __init__(self, rc=0, out="", err=""):
        self.returncode, self.stdout, self.stderr = rc, out, err


def _gql_ok():
    """Main's rollup with every required context green, in the GraphQL shape the code reads."""
    nodes = [{"__typename": "CheckRun", "name": n, "status": "COMPLETED",
              "conclusion": "SUCCESS", "detailsUrl": "https://x/actions/runs/1/job/2"}
             for n in objective.REQUIRED]
    return _Result(0, json.dumps({"data": {"repository": {"object": {
        "statusCheckRollup": {"contexts": {"nodes": nodes}}}}}}))


def install(monkeypatch, *, gql=None, rest=None, pr_list=None, ci_runs=None, ls_remote=None,
            runs=None):
    """Patch the ONE seam every read goes through, and dispatch on the command."""
    def fake_run(cmd, **kw):
        s = " ".join(cmd)
        if "ls-remote" in s:
            return ls_remote if ls_remote is not None else _Result(0, f"{SHA}\trefs/heads/main\n")
        # ⛔ THE SEAM MOVED: `main_sha()` now reads main over `gh`, not `git ls-remote`, because
        # macOS TCC denies a launchd process any read under ~/Documents -- so the old ls-remote
        # branch silently stopped matching and EVERY test saw `main=UNKNOWN@?`. A fixture that
        # no longer matches the call it mocks fails as a WRONG VERDICT, not as a missing stub.
        if "/commits/main" in s:
            return _Result(0, json.dumps({"sha": SHA}))
        if "graphql" in s:
            return gql if gql is not None else _gql_ok()
        if "/check-runs" in s:
            return rest if rest is not None else _Result(1, "", "HTTP 504")
        # The ATTEMPT clock the flight-age bound reads (#1926): `run_started_at` for one run,
        # so a test states the age of ONE attempt. An id it did not stub is a 404 -- an
        # unreadable clock, never a green.
        # ⛔ ANCHORED ON THE EXACT PATH. A bare `/actions/runs/` substring also matches
        # `.../actions/runs/{id}/jobs?per_page=100` (the CI-duration sample) and
        # `.../job/{id}`, and `int()` on those raises INSIDE the fixture -- the first test that
        # stubs a SUCCESSFUL CI sample would crash in the harness rather than fail on behaviour.
        m = re.fullmatch(r".*/actions/runs/(\d+)", s)
        if m:
            return (runs or {}).get(int(m.group(1)), _Result(1, "", "HTTP 404"))
        if cmd[:3] == ["gh", "pr", "list"]:
            return pr_list if pr_list is not None else _Result(0, "[]")
        if "/actions/workflows/" in s:
            return ci_runs if ci_runs is not None else _Result(0, json.dumps({"workflow_runs": []}))
        return _Result(0, "{}")
    monkeypatch.setattr(objective.subprocess, "run", fake_run)


@pytest.fixture(autouse=True)
def _clean_flag():
    """The flag is module state; each test starts from a clean tick."""
    objective.GH_BLOCKED = None
    objective.GH_BLOCKED_BY.clear()
    yield
    objective.GH_BLOCKED = None
    objective.GH_BLOCKED_BY.clear()


# --- DIRECTION 2: a healthy read must NOT flag -----------------------------------------

def test_healthy_read_does_not_flag(monkeypatch):
    install(monkeypatch)
    line = objective.build()
    assert "gh=" not in line, line
    assert "GH-RATE-LIMITED" not in line, line
    assert "main=GREEN" in line, line


def test_optional_ci_read_failure_never_speaks_for_the_fleet(monkeypatch):
    """THE REGRESSION TEST. This is the exact reading that was wrong three times: the
    optional CI-duration sample failed while main and the queue were perfectly readable,
    and the verdict still said the fleet was blind."""
    install(monkeypatch, ci_runs=_Result(1, "", "HTTP 504"))
    line = objective.build()
    assert "gh=" not in line, line
    assert "GH-RATE-LIMITED" not in line, line
    assert "main=GREEN" in line, line


def test_an_unreadable_payload_is_not_blindness(monkeypatch):
    """The transport answered; we mangled the answer. The queue says so locally, the fleet
    does not."""
    install(monkeypatch, pr_list=_Result(0, "not json at all"))
    line = objective.build()
    assert "queue=UNREADABLE" in line, line
    assert "gh=" not in line, line
    assert "GH-RATE-LIMITED" not in line, line


def test_a_surface_outside_the_blinding_set_cannot_flag():
    """Structural, not incidental: an unknown surface is refused by name, so a future
    optional read cannot blind the fleet by being wired to the wrong helper."""
    objective._note_gh_failure("HTTP 504 gateway", "ci-durations")
    assert objective.GH_BLOCKED is None
    assert objective.GH_BLOCKED_BY == []


def test_a_non_transport_text_does_not_flag_even_for_a_blinding_surface():
    objective._note_gh_failure("unparseable queue response: {", "queue", transport=False)
    assert objective.GH_BLOCKED is None
    assert objective.GH_BLOCKED_BY == []


# --- DIRECTION 1: a real outage must STILL flag -----------------------------------------

def test_real_outage_still_flags_blind(monkeypatch):
    """Both transports down for main AND the queue: the fleet genuinely cannot see."""
    limited = _Result(1, "", "API rate limit exceeded for user ID 81560491")
    install(monkeypatch, gql=limited, rest=limited, pr_list=limited)
    line = objective.build()
    assert "gh=RATE-LIMITED(" in line, line
    assert "GH-RATE-LIMITED" in line, line


def test_a_504_outage_flags_as_unreadable(monkeypatch):
    """A non-rate-limit outage still sets the flag, and names BOTH surfaces.

    The VERDICT here is UNKNOWN, not GH-BLOCKED, and that is deliberate — see the
    test below. The flag is the thing the user's rule governs; the verdict is the
    alerting surface and is left alone.
    """
    outage = _Result(1, "", "HTTP 504: Server Error")
    install(monkeypatch, gql=outage, rest=outage, pr_list=outage)
    line = objective.build()
    assert "gh=UNREADABLE(main+queue)" in line, line
    assert "VERDICT=UNKNOWN" in line, line


# --- ATTRIBUTION: the token must name WHICH read failed ---------------------------------

def test_a_queue_only_failure_names_the_queue_and_keeps_main_visible(monkeypatch):
    """THE EXACT FALSE LINE THE ORCHESTRATOR EMITTED, now attributed.

    It used to read `VERDICT=UNKNOWN main=UNKNOWN@? gh=UNREADABLE queue=UNREADABLE`, in
    which `gh=UNREADABLE` named the wrong subsystem and gave no clue that main had been
    readable all along. Two things are now true and both are asserted:
      * main is REPORTED as the state it actually is, so the reading carries the
        information it was hiding; and
      * the token names the failing read, so no lane has to re-derive `is gh down?`.

    The verdict is UNKNOWN and stays UNKNOWN: with the queue unreadable the objective
    cannot be judged, and `gh=UNREADABLE` deliberately does NOT become the alerting
    verdict (only RATE-LIMITED does) -- a transient 504 on one heavy `gh pr list` should
    not page anyone. That asymmetry is recorded as a finding, not silently changed.
    """
    install(monkeypatch, pr_list=_Result(1, "", "HTTP 504: Server Error"))
    line = objective.build()
    assert "gh=UNREADABLE(queue)" in line, line
    assert "main=GREEN" in line, line
    assert "VERDICT=UNKNOWN" in line, line


def test_both_surfaces_are_named_when_both_fail(monkeypatch):
    outage = _Result(1, "", "HTTP 504: Server Error")
    install(monkeypatch, gql=outage, rest=outage, pr_list=outage)
    line = objective.build()
    assert "gh=UNREADABLE(main+queue)" in line, line


def test_main_recovering_withdraws_only_mains_claim(monkeypatch):
    """A GraphQL read means the fleet can see main again; a queue claim recorded in the
    same tick must survive it."""
    install(monkeypatch)
    objective._note_gh_failure("HTTP 504", "queue")
    assert objective.GH_BLOCKED == "UNREADABLE"
    objective.main_health(SHA)                     # GraphQL succeeds
    assert objective.GH_BLOCKED_BY == ["queue"], objective.GH_BLOCKED_BY
    assert objective.GH_BLOCKED == "UNREADABLE", objective.GH_BLOCKED  # the queue still cannot be read


# --- THE OBJECTIVE IS QUALITATIVE: the queue decides the verdict, CI time does not -------
# Owner ruling on #6792 (2026-09-30): "the <10min should be more of a guideline than an
# absolute rule, the objective is more qualitative". Before this, the CI figure was ANDed
# into the verdict, so a slow suite made the instrument report a queue that was AT TARGET as
# if it were not -- and the whole fleet was nudged to chase the demoted number.

def _stub_reads(monkeypatch, *, waiting, crit_max, main_state="GREEN"):
    """Stub the four READERS so the verdict can be exercised on a synthetic state.

    The readers are the seams: main_sha / main_health / queue / ci_critical_path. Stubbing
    them (rather than the `gh` calls) keeps this about the VERDICT, which is what changed.
    """
    monkeypatch.setattr(objective, "main_sha", lambda: SHA)
    monkeypatch.setattr(objective, "main_health", lambda sha: (
        main_state, [] if main_state == "GREEN" else ["python-ci-gate"]))
    monkeypatch.setattr(objective, "queue", lambda: {
        "open": waiting, "drafts": 0, "nondraft": waiting,
        "blocked": 0, "dirty": 0, "unstable": 0})
    monkeypatch.setattr(objective, "ci_critical_path",
                        lambda: (crit_max - 3.0, "test (f)", crit_max))


def test_a_drained_queue_is_at_target_even_when_ci_is_over_the_guideline(monkeypatch):
    """THE REFRAME. A slow suite must not demote a drained queue: CI is an indicator here.

    This is the direction that used to FAIL -- the same state returned ADVANCING because
    `crit_max < TARGET_CI_MIN` was a term in the condition.
    """
    _stub_reads(monkeypatch, waiting=3, crit_max=20.0)
    line = objective.build()
    assert "VERDICT=AT-TARGET" in line, line
    # ...and demoted is not deleted: the duration is still REPORTED, with its guideline status.
    assert "ci_crit_max=20.0m(test (f))" in line, line
    assert "ci_guideline=10m:over" in line, line


def test_a_deep_queue_is_never_at_target_however_fast_ci_is(monkeypatch):
    """The other direction: fast CI cannot buy an AT-TARGET verdict while the queue is deep.

    Removing the CI term must not have made the verdict weaker -- the queue term is the one
    that has to hold, and it does.
    """
    _stub_reads(monkeypatch, waiting=12, crit_max=5.0)
    line = objective.build()
    assert "VERDICT=ADVANCING" in line, line
    assert "ci_guideline=10m:within" in line, line


def test_main_red_still_outranks_the_queue_reading(monkeypatch):
    """The blocking precondition is untouched: a drained queue on a RED main is still BLOCKED,
    because nothing can drain while the required gate is red."""
    _stub_reads(monkeypatch, waiting=2, crit_max=5.0, main_state="RED")
    line = objective.build()
    assert "VERDICT=FIX-MAIN" in line, line
    assert "failing_required=python-ci-gate" in line, line


# --- THE BLIND MERGEABILITY READ: an unread state must never print as a zero --------------
# Measured 2026-10-01: `mergeStateStatus` is computed LAZILY and read UNKNOWN for 75 of 82
# open non-draft PRs at 11:47Z, while the same PRs read BLOCKED from `gh pr view` AND
# `gh pr list` two minutes later. The report printed `blocked=0 conflicting=0` during the
# blind window: a false all-clear. BOTH directions are pinned below.

def _pr(n, ms, draft=False):
    return {"number": n, "isDraft": draft, "mergeable": "MERGEABLE",
            "mergeStateStatus": ms}


def test_a_blind_mergeability_read_is_named_and_cannot_read_as_an_all_clear(monkeypatch):
    """DIRECTION 1. Every PR reading UNKNOWN must SURFACE as its own count.

    The count `blocked=0` is itself honest -- no PR was observed blocked. The defect was
    that it stood ALONE, so an unseen gate was indistinguishable from a clear queue. The
    nudge that dispatches the whole fleet reads this line, so the two must be separable.
    """
    prs = json.dumps([_pr(n, "UNKNOWN") for n in range(1, 76)])
    install(monkeypatch, pr_list=_Result(0, prs))
    line = objective.build()
    assert "mergeable_state_unknown=75" in line, line
    assert "blocked=" not in line, line          # owner ban: no state-words
    assert "queue_read=BLIND" in line, line       # ...but blindness is still NAMED
    assert "nondraft=75" in line, line


def test_a_resolved_mergeability_read_manufactures_no_unknown_bucket(monkeypatch):
    """DIRECTION 2 (the one that keeps the fix honest). A GOOD read must not gain the token.

    Otherwise the new field would be noise on every healthy tick -- and a signal that is
    always present is not a signal.
    """
    prs = json.dumps([_pr(n, "BLOCKED") for n in range(1, 8)]
                     + [_pr(n, "CLEAN") for n in range(8, 11)]
                     + [_pr(n, "DIRTY") for n in range(11, 13)]
                     + [_pr(99, "UNKNOWN", draft=True)])
    install(monkeypatch, pr_list=_Result(0, prs))
    line = objective.build()
    assert "mergeability_unknown" not in line, line
    assert "nondraft=12" in line, line
    assert "mergeable_state_unknown" not in line, line   # resolved => no blind bucket
    assert "resolve-conflict=2" in line, line   # action verb replaced the state-word
def test_a_payload_omitting_the_field_is_blind_not_clear(monkeypatch):
    """A payload that never carries the field is a blind read too, not a clear one.

    `p.get("mergeStateStatus") or "?"` already mapped the omission to a token; the defect
    was that nothing downstream ever reported it.
    """
    install(monkeypatch, pr_list=_Result(0, json.dumps(
        [{"number": n, "isDraft": False} for n in range(1, 5)])))
    line = objective.build()
    assert "mergeable_state_unknown=4" in line, line
    assert "blocked=" not in line, line          # owner ban: no state-words
    assert "queue_read=BLIND" in line, line       # ...but blindness is still NAMED
def test_a_draft_never_contributes_to_the_unknown_count(monkeypatch):
    """Drafts are outside the queue, so they cannot inflate its blindness either."""
    install(monkeypatch, pr_list=_Result(0, json.dumps(
        [_pr(n, "UNKNOWN", draft=True) for n in range(1, 40)] + [_pr(50, "CLEAN")])))
    line = objective.build()
    assert "mergeability_unknown" not in line, line
    assert "nondraft=1" in line and "drafts=39" in line, line


# --- THE VERDICT MUST BE ABLE TO GO RED ON A GROWING BACKLOG ------------------------------
# Measured 2026-10-08: the SAME `ADVANCING` was emitted while the open count ran 12 -> 19 -> 21
# (a ~75% backlog growth). The verdict was main-green AND queue-above-target, with no DIRECTION
# term, so the one outcome the objective ("DRAIN THE PR BACKLOG") exists to detect read as
# success. Direction is a first difference of the `nondraft=` counter this file already prints,
# taken against the previous run's own sample (the same one `state_age` is derived from).

def test_a_queue_that_grew_across_the_window_is_not_advancing(monkeypatch):
    """The regression: a backlog that ROSE must never read ADVANCING."""
    _stub_reads(monkeypatch, waiting=21, crit_max=12.0)
    line = objective.build(prev=(12, 120.0))
    assert "VERDICT=REGRESSING" in line, line


def test_a_queue_that_shrank_or_held_keeps_advancing(monkeypatch):
    """And the term must not be a blanket red: shrinking and steady are still progress."""
    _stub_reads(monkeypatch, waiting=12, crit_max=12.0)
    assert "VERDICT=ADVANCING" in objective.build(prev=(21, 120.0)), "shrank"
    assert "VERDICT=ADVANCING" in objective.build(prev=(12, 120.0)), "steady"


def test_a_stale_sample_does_not_manufacture_a_growth_verdict(monkeypatch):
    """Two hours apart is not evidence the queue grew *now*; direction must be UNKNOWN, not red."""
    _stub_reads(monkeypatch, waiting=21, crit_max=12.0)
    line = objective.build(prev=(12, 7200.0))
    assert "VERDICT=ADVANCING" in line, line


# --- #1926: A CHECK-RUN THAT NEVER COMPLETES IS NOT "IN FLIGHT" FOREVER --------------------
# GitHub does not reconcile a run that was never picked up (a cancelled workflow, a runner that
# never came up, a job created and then orphaned): `status` stays non-`completed` at that head
# PERMANENTLY. Nothing in the classifier looked at a check's AGE, so the shape could never
# leave it: the re-trigger arm requires `not req_seen` (and `not flight` on the #1872 branch),
# and a wedged run is absent from `seen` while its healthy siblings are not. MEASURED pre-fix
# at main=57edbd7a0, `classify_queue` on the state below returns `{'fix-ci': 1}` -- "go repair
# the code" for a job that never ran.
#
# The fix carries the ONE missing dimension: the ATTEMPT's age. Pinned below, both ways: below
# the bound nothing changes (a slow shard is not a stuck one), above it the class is the
# re-trigger the issue asks for, with a reason naming the check and its age.

NOW = 1_800_000_000.0                  # a FIXED clock: the bound is pinned, not the wall clock
# An age past the bound by a wide margin. A LITERAL, not `FLIGHT_BOUND_MIN + something`: the
# constant's own range is pinned separately, so this cannot drift out of validity silently.
WEDGED_MIN = 150
# The contexts a landing waits on, spelled INDEPENDENTLY of the code. That does NOT make the
# tests below fail behaviourally pre-fix: `stalled_flight` is a new symbol, so a pre-fix run
# fails most of them with AttributeError. The BEHAVIOURAL pre-fix failure is
# `test_the_beat_names_the_wedged_check_and_its_age` (it drives `classify_queue` only, and
# reads `{'fix-ci': 1}` where the fix produces `rerun-checks`); the rest pin the contract.
GATED_FOR_TEST = ("pricing-artifact", "docs", "test-isolation", "license-surface",
                  "legal-e2e", "python-ci-gate")

_SEQ = itertools.count(1)


def _iso(ts):
    """The shape GitHub returns: `2026-10-17T05:30:12Z`."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def _run(name, status, *, started_min=None, conclusion=None, run=9001, app="github-actions"):
    """A REST check-run in the shape `per_pr_checks()` reads (see a live body: `check_suite` is
    an id, `started_at` is NULL for a run that never started, and `details_url` carries the
    ACTIONS RUN id). The `id` is a counter, so the LAST one built is the NEWEST ATTEMPT -- the
    rule the code groups by."""
    cid = next(_SEQ)
    c = {"id": cid, "name": name, "status": status, "conclusion": conclusion,
         "details_url": f"https://x/actions/runs/{run}/job/{cid}",
         "app": {"slug": app}}
    if started_min is not None:
        c["started_at"] = _iso(NOW - started_min * 60)
    return c


def _clock(*, attempt_min):
    """The injected run clock: every run's current attempt started `attempt_min` ago."""
    return lambda run_id: None if run_id is None else NOW - attempt_min * 60


def _wedged_cr(*, age_min=WEDGED_MIN, status="queued", started=False, wedge="python-ci-gate",
               run=9001):
    """Gated checks green, `wedge` non-completed. Extras must be appended by the CALLER (the
    fixture builds in order, and the newest attempt is the last one built)."""
    cr = [_run(n, "completed", conclusion="success")
          for n in GATED_FOR_TEST if n != wedge]
    cr.append(_run(wedge, status, run=run,
                   started_min=age_min if started else None))
    return cr


def _a_pr(ms="UNSTABLE"):
    return {"number": 8822, "mergeStateStatus": ms, "headRefOid": "a" * 40, "files": []}


def test_a_run_past_the_bound_is_rerun_checks_not_a_wait():
    """THE DEFECT. A required check left `queued` -- the shape the issue names -- others green.

    PRE-FIX `classify_pr` answers `fix-ci`: the beat sends a lane to repair code for a job that
    never ran, and the re-trigger never happens. POST-FIX it is the actionable class the issue
    asks for, and the reason names the check, its state and its age.
    """
    cr = _wedged_cr(age_min=WEDGED_MIN)
    assert objective.classify_pr(_a_pr(), cr, False) == "fix-ci"     # no age term today
    stalled = objective.stalled_flight(cr, now=NOW, run_clock=_clock(attempt_min=WEDGED_MIN))
    assert [(n, st) for n, st, _a in stalled] == [("python-ci-gate", "queued")]
    assert round(stalled[0][2]) == WEDGED_MIN
    assert objective.classify_pr(_a_pr(), cr, False, stalled) == "rerun-checks"


def test_below_the_bound_a_slow_run_is_still_a_wait(monkeypatch):
    """THE OTHER SIDE, END TO END through `classify_queue` -- the fix must not turn a SLOW run
    into a re-trigger. 20 minutes into a queued suite is the NORMAL state of a push."""
    cr = _wedged_cr(age_min=20, status="in_progress", started=True)
    install(monkeypatch, rest=_Result(0, json.dumps([{"check_runs": cr}])),
            runs={9001: _Result(0, json.dumps({"run_started_at": _iso(NOW - 20 * 60)}))})
    monkeypatch.setattr(objective, "attestation_clean", lambda n, h: False)
    monkeypatch.setattr(objective.time, "time", lambda: NOW)
    classes, _surface, by_class = objective.classify_queue([_a_pr()])
    assert classes["rerun-checks"] == 0, classes
    assert "rerun-checks" not in by_class, by_class


def test_the_bound_is_a_constant_pinned_on_both_sides():
    """A bound nobody pins is a number that drifts. Just either side of it: +-1 minute."""
    # ...and it must stay in the range `WEDGED_MIN` is above, so a retune cannot invalidate it.
    assert 60.0 <= objective.FLIGHT_BOUND_MIN <= 120.0, objective.FLIGHT_BOUND_MIN
    # ...and the set it ages is the required set MINUS the diff-bound gate, which has its own
    # evidence (the attestation file) and cannot be repaired by a re-run.
    assert objective.GATED_CHECKS == GATED_FOR_TEST, objective.GATED_CHECKS
    # ...and above the queue-INCLUSIVE wall time this file documents (44.3m): the clock for a
    # never-started run includes the runner queue, so a bound below that would fire on normal
    # load. That is the derivation the constant's comment states.
    assert objective.FLIGHT_BOUND_MIN > 44.3
    below = _wedged_cr(age_min=objective.FLIGHT_BOUND_MIN - 1, status="in_progress",
                       started=True)
    above = _wedged_cr(age_min=objective.FLIGHT_BOUND_MIN + 1, status="in_progress",
                       started=True)
    assert objective.stalled_flight(below, now=NOW) == []
    assert len(objective.stalled_flight(above, now=NOW)) == 1


def test_a_re_trigger_resets_the_age(monkeypatch):
    """THE ANTI-CHURN PIN. A re-run REUSES the check suite (MEASURED 2026-10-17, agent-infra run
    39004542024: attempts 1 and 2 both carry suite 105706798511) while the RUN's
    `run_started_at` advances. So the age must come from the run's CURRENT attempt: aged from
    the suite's original `created_at`, a PR whose wedge was just re-triggered would read wedged
    again on the very next beat and be re-triggered forever."""
    # the same check, re-triggered into a NEW run whose current attempt started 2m ago
    cr = _wedged_cr(age_min=None, run=9100)
    clock = _clock(attempt_min=2)
    assert objective.stalled_flight(cr, now=NOW, run_clock=clock) == []
    # ...and the pre-re-trigger run, whose attempt started WEDGED_MIN ago, IS wedged
    cr_old = _wedged_cr(age_min=None, run=9001)
    assert len(objective.stalled_flight(cr_old, now=NOW,
                                       run_clock=_clock(attempt_min=WEDGED_MIN))) == 1


def test_the_attempt_clock_is_read_once_per_run_and_only_when_needed(monkeypatch):
    """A started check carries its own `started_at`, so it must cost NO run read -- the fleet's
    GitHub budget is shared and rate-limited. A queued one spends exactly one read per RUN."""
    seen = []

    def fake_run(cmd, **kw):
        s = " ".join(cmd)
        seen.append(s)
        if "/actions/runs/" in s:
            return _Result(0, json.dumps({"run_started_at": _iso(NOW - WEDGED_MIN * 60)}))
        return _Result(0, "{}")
    monkeypatch.setattr(objective.subprocess, "run", fake_run)
    clock = objective._pass_run_clock()
    # Two gated checks in ONE run, plus one that has already STARTED -- in its OWN run, left
    # UNSTUBBED (so a read for it is a 404). The pin is the CALL COUNT: one read for the run
    # that needs a clock, none for the started check (which ages by its own `started_at`), and
    # still one on the second pass (the per-pass memo). `docs` is asserted STALLED, so a clock
    # that 404s and thereby LOST the started check would fail here too.
    cr = [_run("python-ci-gate", "queued", run=9001),
          _run("legal-e2e", "queued", run=9001),
          _run("docs", "in_progress", started_min=WEDGED_MIN, run=9002)]
    first = objective.stalled_flight(cr, now=NOW, run_clock=clock)
    second = objective.stalled_flight(cr, now=NOW, run_clock=clock)
    assert len(seen) == 1, seen
    assert [n for n, _st, _a in first] == ["docs", "legal-e2e", "python-ci-gate"], first
    assert [n for n, _st, _a in second] == ["docs", "legal-e2e", "python-ci-gate"], second


def test_an_unreadable_clock_leaves_the_run_in_flight():
    """ABSENCE IS NOT EVIDENCE. If the clock cannot be read the run stays in flight (unchanged
    behaviour) -- an unreadable age must never manufacture a re-trigger."""
    cr = _wedged_cr(age_min=None)
    assert objective.stalled_flight(cr, now=NOW, run_clock=lambda rid: None) == []
    assert objective.stalled_flight(cr, now=NOW, run_clock=None) == []
    assert objective.classify_pr(_a_pr(), cr, False, []) == "fix-ci"


def test_a_red_check_is_work_even_beside_a_wedged_one():
    """A RED gated check is NEVER masked by the re-trigger: re-running the suite would only
    hide real code work for a pass (the same rule the `running` verdict states, #1872)."""
    cr = _wedged_cr(age_min=WEDGED_MIN)
    cr.append(_run("docs", "completed", conclusion="failure"))     # newest docs attempt: RED
    stalled = objective.stalled_flight(cr, now=NOW, run_clock=_clock(attempt_min=WEDGED_MIN))
    assert stalled, "the wedge is still reported"
    assert objective.classify_pr(_a_pr(), cr, False, stalled) == "fix-ci"


def test_ordering_follows_the_recorded_ladder_and_the_gate_is_never_aged():
    """Two ordering facts pinned by the arms, not by accident:
    * a WEDGED check outranks a DIRTY one (`rerun-checks` sits ABOVE `resolve-conflict` in
      `CLASS_ORDER`, which is the owner-designed ladder: a missing check tells you NOTHING and a
      rebase CHANGES THE HEAD). An arm placed after the conflict arm would silently diverge from
      that recorded order;
    * `ai-review-gate` is DIFF-BOUND and is never in the aged set (a re-run cannot make an
      attestation appear), so a stalled gate alone never reads `rerun-checks`."""
    cr = _wedged_cr(age_min=WEDGED_MIN)
    stalled = objective.stalled_flight(cr, now=NOW, run_clock=_clock(attempt_min=WEDGED_MIN))
    assert objective.classify_pr(_a_pr(ms="DIRTY"), cr, False, stalled) == "rerun-checks"
    gate = [_run(n, "completed", conclusion="success")
            for n in GATED_FOR_TEST if n != "ai-review-gate"]
    gate.append(_run("ai-review-gate", "queued", run=9002))
    assert objective.stalled_flight(gate, now=NOW,
                                    run_clock=_clock(attempt_min=WEDGED_MIN)) == []


def test_two_workflows_sharing_a_job_name_are_named_once_by_the_older_attempt():
    """`docs` published by two workflows, both stuck. `rollup_checks` collapses the pair to one
    name, so the reason must too -- and it keeps the OLDER attempt, the one that has been stuck
    longest. The clock VARIES by run id, so an implementation that kept the newest attempt
    (the fixture's last one) would report WEDGED_MIN and fail here."""
    cr = _wedged_cr(age_min=None, wedge="docs", run=9001)
    cr.append(_run("docs", "queued", run=9003))                    # newest attempt, YOUNGER
    ages = {_run_id: min for _run_id, min in (("9001", WEDGED_MIN + 30), ("9003", WEDGED_MIN))}
    stalled = objective.stalled_flight(
        cr, now=NOW, run_clock=lambda rid: NOW - ages[rid] * 60)
    assert [(n, st) for n, st, _a in stalled] == [("docs", "queued")]
    assert round(stalled[0][2]) == WEDGED_MIN + 30


def test_the_beat_names_the_wedged_check_and_its_age(monkeypatch):
    """END TO END through the classifier the beat actually prints: `rerun-checks=1:
    #8822(python-ci-gate queued 150m)` -- WHICH check, in which state, for how long. A bare
    `rerun-checks=1: #8822` would make a wedged run and a head whose checks never got created
    look identical, and they need different repairs."""
    cr = _wedged_cr(age_min=None)
    install(monkeypatch, rest=_Result(0, json.dumps([{"check_runs": cr}])),
            runs={9001: _Result(0, json.dumps({"run_started_at": _iso(NOW - WEDGED_MIN * 60)}))})
    monkeypatch.setattr(objective, "attestation_clean", lambda n, h: False)
    monkeypatch.setattr(objective.time, "time", lambda: NOW)
    classes, _surface, by_class = objective.classify_queue([_a_pr()])
    assert classes["rerun-checks"] == 1, classes
    why = f"python-ci-gate queued {WEDGED_MIN}m"
    assert by_class["rerun-checks"] == [(8822, why)], by_class
    assert (objective._class_token("rerun-checks", 1, by_class["rerun-checks"])
            == f"rerun-checks=1: #8822({why})")
