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
import json
import pathlib

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


def install(monkeypatch, *, gql=None, rest=None, pr_list=None, ci_runs=None, ls_remote=None):
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
