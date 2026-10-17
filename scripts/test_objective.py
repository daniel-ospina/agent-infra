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

import atexit
import importlib.util
import json
import pathlib
import shutil
import subprocess
import tempfile

import pytest

_SPEC = importlib.util.spec_from_file_location(
    "objective_under_test", pathlib.Path(__file__).with_name("objective.py"))
objective = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(objective)

# ⛔ THE SUITE MUST NOT PERSIST INTO THE LIVE LOOP'S STATE DIRECTORY (#1734, its second instance).
# `objective.py` persists BETWEEN HEARTBEAT BEATS: `_stuck_bump` writes -- and, with no
# `call-rail` PR in the fixture, TRUNCATES -- `~/.pi/agent/state/call-rail-stuck.json`, the file
# the live loop maintains to escalate a `call-rail` PR that has gone quiet. Measured 2026-10-17:
# a single `pytest scripts/test_objective.py` run left that file as `{}`. The redirect belongs
# HERE, at load, because `build()` is what persists and every test calls it.
# ⛔ REDIRECTING `STATE` DOES NOT COVER A PATH ADDED LATER: the module resolves its paths AT
# IMPORT (`STUCK_FILE = os.path.join(STATE, ...)`), so a new state constant would compute itself
# from the LIVE dir before this override runs. Each existing path is therefore named here, and
# `test_the_suite_never_persists_into_the_live_state_dir` enumerates the module's own string
# constants for leftovers -- a new one fails that test instead of silently writing production
# state (the "one seam, every consumer" property, made mechanical).
_STATE_SCRATCH = tempfile.mkdtemp(prefix="objective-state-")
atexit.register(shutil.rmtree, _STATE_SCRATCH, ignore_errors=True)
objective.STATE = _STATE_SCRATCH
objective.CACHE = str(pathlib.Path(_STATE_SCRATCH) / "objective.last")
objective.STUCK_FILE = str(pathlib.Path(_STATE_SCRATCH) / "call-rail-stuck.json")

SHA = "9c4788400" + "b" * 31
# #1872: the class segment is STATE, not a dispatch list -- the old `DO:` token is gone by design
# (a monitor must not instruct the fleet to do work the dispatch chain owns).
QUEUE_SEG = "| QUEUE(state; pr-doctor dispatches):"


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
    """Patch the ONE seam every read goes through, and dispatch on the command.

    `pr_list` may be a SEQUENCE of `_Result`s: one QUEUE response per read, the last one
    repeating once the sequence is spent (#1869's re-sample makes the queue read happen more
    than once). Returns the list the re-sample backoff appends to -- `objective._sleep` is
    patched to RECORD rather than wait, so the retry's budget is asserted instead of slept
    through (CI bounds every test at 60 s).
    """
    queue_reads = {"n": 0}
    sleeps = []

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
            seq = (list(pr_list) if isinstance(pr_list, (list, tuple))
                   else [pr_list if pr_list is not None else _Result(0, "[]")])
            i = min(queue_reads["n"], len(seq) - 1)
            queue_reads["n"] += 1
            return seq[i]
        if "/actions/workflows/" in s:
            return ci_runs if ci_runs is not None else _Result(0, json.dumps({"workflow_runs": []}))
        return _Result(0, "{}")
    monkeypatch.setattr(objective.subprocess, "run", fake_run)
    monkeypatch.setattr(objective, "_sleep", sleeps.append)
    return sleeps


@pytest.fixture(autouse=True)
def _clean_flag():
    """The flag is module state; each test starts from a clean tick."""
    objective.GH_BLOCKED = None
    objective.GH_BLOCKED_BY.clear()
    yield
    objective.GH_BLOCKED = None
    objective.GH_BLOCKED_BY.clear()


@pytest.fixture(autouse=True)
def _isolate_stuck_ledger(tmp_path, monkeypatch):
    """⛔ `build()` WRITES the STUCK ledger, so a test run must not touch the fleet's own.

    `build()` -> `_stuck_bump()` opens `STUCK_FILE` (under `~/.pi/agent/state/`) and rewrites it
    with whatever `call-rail` PRs the FIXTURE happens to contain -- normally `{}`. MEASURED 2026-10-17
    (reviewer, #1872 review round 5): a suite run took the real file from
    `{"1234": 3, "5678": 5}` to `{}` and bumped its mtime. The consequence is not cosmetic: that
    ledger is what turns `call-rail` into "STUCK N beats -- pr-doctor has not landed it", so any
    lane running this suite silently suppressed the fleet's one escalation for the next two beats.

    Every test in this file that calls `build()` gets a private state dir; a test that wants to
    inspect the ledger can still point `STUCK_FILE` at its own `tmp_path` explicitly.
    """
    monkeypatch.setattr(objective, "STATE", str(tmp_path))
    monkeypatch.setattr(objective, "STUCK_FILE", str(tmp_path / "call-rail-stuck.json"))


def test_the_fixture_redirects_the_state_dir_and_the_stuck_ledger():
    """⛔ THE REDIRECT MUST BE IN FORCE, NOT MERELY WRITTEN (#1872 review round 7).

    The autouse fixture above only prevents the ledger wipe while it EXISTS. A test that pins the
    redirect is what makes DELETING it fail: `test_lane_actions.py` pins the identical seam
    (`test_the_suite_never_points_at_the_production_state_dir`) for its own module, and this file
    had none -- so the fix could be removed with the WHOLE FILE still green while every run resumed
    rewriting `~/.pi/agent/state/call-rail-stuck.json` to `{}` and silently suppressing `call-rail`'s
    one escalation. Verified by hand: deleting the two `monkeypatch.setattr` lines left every test
    passing and the real ledger at `{}`.

    Deliberately no test count: "the whole file is green" is the property that reproduces, and a
    figure would only date this sentence.
    """
    prod = str(pathlib.Path.home() / ".pi" / "agent" / "state")
    for name in ("STATE", "STUCK_FILE"):
        value = getattr(objective, name)
        assert not value.startswith(prod), f"{name} points at production: {value}"


def test_a_REFUSED_queue_still_names_the_surface_prs(monkeypatch):
    """⛔ THE OWNER'S LIST SURVIVES THE REFUSAL (#1872 review round 11).

    `classify_queue()` returns a refusal tuple when the buckets are not a usable partition. Its
    docstring used to document that tuple as `(None, n, {}, [])` -- with `surface_prs` DROPPED --
    which is the opposite of the code and of why the names exist: a gate whose output is "N things
    need you" without naming them is a stall with a receipt, and an UNREADABLE pass is exactly when
    the owner's list matters most. Nothing pinned it, so the drop could have come back silently.
    """
    non = [{"number": 1, "files": []}, {"number": 2, "files": []}, {"number": 3, "files": []}]
    monkeypatch.setattr(objective, "touches_surface", lambda p: p["number"] in (1, 3))

    # (a) ONE unreadable PR refuses the pass, and the names still come back
    monkeypatch.setattr(objective, "classify_one",
                        lambda p: (None, None, None) if p["number"] == 2 else ("running", None, []))
    classes, surface, by_class, surface_prs = objective.classify_queue(non)
    assert classes is None and by_class == {}, (classes, by_class)
    assert surface == 2 and surface_prs == [1, 3], (surface, surface_prs)

    # (b) the OTHER trigger -- buckets that do not reconcile with `nondraft` -- behaves the same way
    monkeypatch.setattr(objective, "classify_one",
                        lambda p: ("not-a-class", None, []) if p["number"] == 2 else ("running", None, []))
    classes, surface, by_class, surface_prs = objective.classify_queue(non)
    assert classes is None and by_class == {}, (classes, by_class)
    assert surface_prs == [1, 3], surface_prs


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


def test_the_FAIL_CLOSED_caveat_precedes_the_counts_it_qualifies(tmp_path, monkeypatch):
    """⛔ THE CAVEAT'S POSITION IS THE GUARANTEE, NOT THE LENGTH OF THE LINE (#1872 review r3).

    `cadence-nudge.sh` reads this line with a fixed `cut`. The width was re-argued several times and
    every answer went stale as the queue grew -- but the property
    that actually matters is structural: a truncated line must never lose the token that says the
    counts are NOT a clearance. That holds only while `queue_read=BLIND` is emitted BEFORE the
    `QUEUE(` segment, so the ordering is pinned here instead of being described in a comment
    nobody can enforce.

    The same argument covers `ASK-USER` (#1872 review round 4): it names the surface PRs because
    the count alone is not actionable, so a deep queue must not be able to sever the names and
    leave the bare count the overlay was added to replace.
    """
    prs = json.dumps([dict(_pr(n, "UNKNOWN"),
                           files=[{"path": "tortoise/sdk.py"}] if n % 3 == 0 else [])
                      for n in range(1, 15)])
    install(monkeypatch, pr_list=_Result(0, prs))
    line = objective.build()
    assert "queue_read=BLIND" in line and "| QUEUE(state;" in line, line
    assert line.index("queue_read=BLIND") < line.index("| QUEUE(state;"), line
    # ...and the OWNER'S list is protected the same way: it cannot be the token a deep queue
    # severs. MEASURED before this: 60 non-draft PRs with a 20-PR overlay lost all 20 names.
    assert "ASK-USER: surface=" in line, line
    assert line.index("ASK-USER: surface=") < line.index("| QUEUE(state;"), line


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


def test_the_suite_never_persists_into_the_live_state_dir(monkeypatch):
    """THE REDIRECT MUST BE IN FORCE, NOT MERELY PRESENT (#1734, second instance).

    `build()` persists `call-rail-stuck.json` on every call that reaches the DO branch -- so a
    test run against the real `~/.pi/agent/state` truncates the live loop's escalation counter,
    and deleting the redirect would do it again silently. Asserted on the loaded module, which
    is the seam every test in this file goes through, and ENUMERATED rather than listed: a state
    path added later fails here instead of quietly pointing at production.
    """
    live = str(pathlib.Path.home() / ".pi" / "agent" / "state")
    leaked = {name: value for name, value in vars(objective).items()
              if isinstance(value, str) and value.startswith(live)}
    assert not leaked, leaked
    assert pathlib.Path(objective.STATE).is_dir(), objective.STATE
    # ...and the persistence path really runs, so the assertion above is not vacuous.
    install(monkeypatch, pr_list=_Result(0, json.dumps([_pr(1, "BLOCKED")])))
    objective.build()
    assert pathlib.Path(objective.STUCK_FILE).parent == pathlib.Path(objective.STATE)
    assert pathlib.Path(objective.STUCK_FILE).exists()


def test_a_draft_never_contributes_to_the_unknown_count(monkeypatch):
    """Drafts are outside the queue, so they cannot inflate its blindness either."""
    install(monkeypatch, pr_list=_Result(0, json.dumps(
        [_pr(n, "UNKNOWN", draft=True) for n in range(1, 40)] + [_pr(50, "CLEAN")])))
    line = objective.build()
    assert "mergeability_unknown" not in line, line
    assert "nondraft=1" in line and "drafts=39" in line, line


# --- #1869: A LAZILY-COMPUTED MERGE STATE IS RE-SAMPLED, NOT DECLARED BLIND ---------------
# MEASURED 2026-10-16, two consecutive beats: 13:25 printed a full DO list, 13:34 printed
# `queue_read=BLIND(14/14 unread)` and a DO list that had LOST `call-rail` and
# `resolve-conflict` -- and the SAME read minutes later returned
# `{BLOCKED: 8, DIRTY: 5, UNSTABLE: 1}`. The state was not wrong, it was NOT READY YET
# (`mergeStateStatus` is recomputed on every base/head move), and `_gh_retry` cannot see that
# because the transport SUCCEEDED. A lane acting on that beat's line treated two landable PRs
# as "STUCK 13 beats" when both were `mergeable=true` the whole time.
# ⇒ the queue read is SAMPLED AGAIN, and blindness is declared only if it never settles.

def _blind_prs(n, lo=1):
    return json.dumps([_pr(i, "UNKNOWN") for i in range(lo, lo + n)])


def test_a_transiently_unknown_queue_is_resampled_and_keeps_its_do_list(monkeypatch):
    """ACCEPTANCE 1 of #1869 -- the exact behaviour that failed.

    First sample all-UNKNOWN, second sample real states: the beat must show the WORK, not
    drop it. A blind first sample is not a blind queue.
    """
    sleeps = install(monkeypatch, pr_list=[
        _Result(0, _blind_prs(2)),
        _Result(0, json.dumps([_pr(1, "DIRTY"), _pr(2, "BLOCKED")]))])
    line = objective.build()
    assert "queue_read=BLIND" not in line, line          # the transient was absorbed
    assert "mergeable_state_unknown" not in line, line   # ...and no stale blind count either
    assert "queue_read=SETTLED(samples=2)" in line, line  # ...and the retry is NOT silent
    assert QUEUE_SEG in line, line
    assert "resolve-conflict=1" in line and "record-review=1" in line, line
    assert sleeps == [objective.QUEUE_BLIND_BACKOFF_S[0]], sleeps


def test_a_queue_unreadable_on_every_sample_still_reports_blind(monkeypatch):
    """ACCEPTANCE 2 of #1869 -- the retry must not become a FAIL-OPEN.

    Every sample unread => BLIND, exactly as before, and the re-sample stops at its own bound
    instead of looping (the backoff is popped once per re-read, so `len(sleeps)` IS the
    attempt count).
    """
    sleeps = install(monkeypatch, pr_list=[_Result(0, _blind_prs(14))])
    line = objective.build()
    assert f"queue_read=BLIND(14/14 unread, samples={objective.QUEUE_BLIND_ATTEMPTS})" in line, line
    assert "queue_read=SETTLED" not in line, line
    assert len(sleeps) == objective.QUEUE_BLIND_ATTEMPTS - 1, sleeps
    assert sum(sleeps) <= 20, sleeps          # a SHORT backoff: the beat has a 90 s budget


def test_a_blind_do_list_is_still_never_a_clearance(monkeypatch):
    """ACCEPTANCE 3 of #1869 -- the property that must SURVIVE the fix.

    A DO list printed from a blind read is not a clearance, and re-sampling must not launder
    it into one: the token that says so stays beside it. A queue that improves but never
    settles is reported from its BEST sample -- and still declared BLIND.
    """
    install(monkeypatch, pr_list=[
        _Result(0, _blind_prs(14)),
        _Result(0, json.dumps([_pr(i, "UNKNOWN") for i in range(1, 9)]
                              + [_pr(i, "BLOCKED") for i in range(9, 15)]))])
    line = objective.build()
    assert "queue_read=BLIND(8/14 unread, samples=" in line, line   # best sample, still blind
    assert "the QUEUE counts are NOT a clearance" in line, line
    assert QUEUE_SEG in line, line
    assert "queue_read=SETTLED" not in line, line


def test_a_readable_queue_is_read_once(monkeypatch):
    """...and the fix costs nothing on a healthy tick: no extra API call, no waiting."""
    sleeps = install(monkeypatch, pr_list=[_Result(0, json.dumps(
        [_pr(n, "BLOCKED") for n in range(1, 5)]))])
    line = objective.build()
    assert "queue_read=" not in line, line
    assert sleeps == [], sleeps


def test_the_resample_is_bounded_by_WALL_CLOCK_not_only_by_attempts(monkeypatch):
    """A slow read must not be handed a full ladder of sleeps on top of it.

    An attempt count bounds the number of READS, not the time they cost: the read can be slow
    (a full recompute measured ~12 s, and one hung `gh` costs up to its own 120 s timeout), and
    the beat's whole refresh is killed at 90 s (`heartbeat-loop.sh`, `run_bounded 90`) -- a
    killed refresh writes NO line at all, which is worse than an honest BLIND. So the deadline
    is checked before every re-read, and a spent budget stops the loop from re-reading.
    """
    sleeps = install(monkeypatch, pr_list=[_Result(0, _blind_prs(14))])
    ticks = iter([0.0] + [objective.QUEUE_BLIND_BUDGET_S + 1.0] * 8)
    monkeypatch.setattr(objective, "_monotonic", lambda: next(ticks))
    reads = []
    real = objective._gh_retry
    monkeypatch.setattr(
        objective, "_gh_retry", lambda *a, **k: (reads.append(1), real(*a, **k))[1])
    line = objective.build()
    assert "queue_read=BLIND(14/14 unread, samples=1)" in line, line
    assert len(reads) == 1, reads          # no second re-read once the budget is spent
    # ...and the wait that followed it was CLIPPED to the zero budget left, not slept in full.
    assert sleeps == [0.0], sleeps


def test_the_blind_token_precedes_the_list_it_qualifies(monkeypatch):
    """ORDERING IS SEMANTICS to a truncating reader (#1869 acceptance 3, hardened).

    The token that says "these counts are NOT a clearance" used to be appended AFTER the class list
    segment, and the fleet brief cuts this line (`cadence-nudge.sh`: `cut -c1-900`, raised from 400
    in #1872) -- so a growing class list pushed the only qualifier past the cut and left the reader
    with a bare action list. Pinned on POSITION, not on presence: the assertion below is about where
    the qualifier sits, and the width is only the budget that position has to fit in.
    """
    install(monkeypatch, pr_list=[_Result(0, _blind_prs(14))])
    line = objective.build()
    qualifier = line.index("queue_read=BLIND")
    assert qualifier < line.index(QUEUE_SEG), line
    assert len(line[:qualifier]) < 900, line      # ...and reachable inside the nudge's cut


def test_a_Minority_unread_read_is_neither_blind_nor_resampled(monkeypatch):
    """THE THRESHOLD ITSELF, which no other fixture exercises (#1869 review).

    Every other fixture is all-UNKNOWN or all-resolved, so the half-the-queue predicate -- and
    the fact that the RETRY and the REPORT share it -- was unpinned: `_blind = _u > 0` in the
    report, or a bare `unknown > 0` predicate, both passed the whole suite. One unread PR in 14
    must be a NAMED count and nothing more: no BLIND, no re-sample, no extra API call.
    """
    sleeps = install(monkeypatch, pr_list=[_Result(0, json.dumps(
        [_pr(1, "UNKNOWN")] + [_pr(n, "BLOCKED") for n in range(2, 15)]))])
    line = objective.build()
    assert "mergeable_state_unknown=1" in line, line
    assert "queue_read=" not in line, line
    assert sleeps == [], sleeps


def test_the_most_resolved_sample_is_the_one_reported(monkeypatch):
    """KEEPING THE BEST SAMPLE, not the last one -- the case the other tests cannot see.

    Every other fixture IMPROVES between samples, so `keep-last` looks identical to `keep-best`.
    A later sample that lands in a SECOND recompute window is the shape that separates them: the
    line must report the better reading (8/14), not the worse one that arrived last (14/14).
    """
    install(monkeypatch, pr_list=[
        _Result(0, json.dumps([_pr(i, "UNKNOWN") for i in range(1, 15)])),
        _Result(0, json.dumps([_pr(i, "UNKNOWN") for i in range(1, 9)]
                              + [_pr(i, "BLOCKED") for i in range(9, 15)])),
        _Result(0, _blind_prs(14))])
    line = objective.build()
    assert "mergeable_state_unknown=8" in line, line
    assert "queue_read=BLIND(8/14 unread, samples=4)" in line, line


def test_a_degenerate_sample_can_never_clear_a_blind_queue(monkeypatch):
    """THE FAIL-OPEN THE RETRY COULD HAVE INTRODUCED (#1869 review, P2).

    "Fewest unread keys" alone lets a degenerate answer win: 14 blind PRs, then an EMPTY list is
    0 unread -- `nondraft=0`, no BLIND token, and `waiting < TARGET_PRS` flips the verdict to
    AT-TARGET. That is the false all-clear this instrument exists to refuse, manufactured by the
    retry itself. A queue that LOST PRs while we waited may not settle the read.
    """
    install(monkeypatch, pr_list=[_Result(0, _blind_prs(14)), _Result(0, "[]")])
    line = objective.build()
    assert "queue_read=BLIND(14/14 unread, samples=4)" in line, line
    assert "nondraft=14" in line, line
    assert "VERDICT=AT-TARGET" not in line, line


def test_an_UNDERCOUNTED_first_sample_is_replaced_by_the_full_queue(monkeypatch):
    """The same false all-clear from the OTHER direction (#1869 review).

    "Fewest unread" with only a shrink guard is one-sided: a degraded FIRST answer that carries 3
    of 14 PRs is never replaced by the larger later sample, because "more unread" was read as
    "worse" regardless of size -- so `waiting=3` on a 14-PR queue and `waiting < TARGET_PRS` says
    AT-TARGET. A sample that GAINED PRs is a MORE COMPLETE read, even with more unread ones.
    """
    install(monkeypatch, pr_list=[_Result(0, _blind_prs(3)), _Result(0, _blind_prs(14))])
    line = objective.build()
    assert "nondraft=14" in line, line
    assert "queue_read=BLIND(14/14 unread, samples=4)" in line, line
    assert "VERDICT=AT-TARGET" not in line, line


def test_the_at_target_verdict_is_about_DEPTH_and_says_so_beside_blindness(monkeypatch):
    """A blind merge state does not falsify the QUEUE DEPTH -- and that is intent, not accident.

    `waiting` is `len(non_drafts)`: a real count of rows GitHub returned, unaffected by whether
    the lazy merge field had settled. So a shallow queue reads AT-TARGET with the BLIND token
    BESIDE it, and neither token is claiming the other's fact: the verdict is about depth, the
    token is about classification. Pinned so a future change to either is a decision, not a
    silent edit (the review asked for exactly this: no consumer re-checks `queue_read`).
    """
    install(monkeypatch, pr_list=[_Result(0, _blind_prs(3))])
    line = objective.build()
    assert "VERDICT=AT-TARGET" in line, line
    assert "queue_read=BLIND(3/3 unread, samples=4)" in line, line
    assert "waiting=3" in line, line


def test_an_unread_merge_state_never_surfaces_as_a_zero_count(monkeypatch):
    """`dirty`/`unstable` are DERIVED counts, so a blind read must yield None, not 0.

    Nothing consumes them today, which is exactly why they are the trap: the next consumer that
    reads `q["dirty"]` on a blind tick would inherit the false zero this file forbids ("an unread
    value must never render as a zero") with no test in its way.
    """
    install(monkeypatch, pr_list=[_Result(0, _blind_prs(4))])
    q = objective.queue()
    assert q["unknown"] == 4, q
    assert q["dirty"] is None and q["unstable"] is None, q
    # ...and a readable read still reports the real counts.
    install(monkeypatch, pr_list=[_Result(0, json.dumps(
        [_pr(1, "DIRTY"), _pr(2, "UNSTABLE"), _pr(3, "BLOCKED")]))])
    q = objective.queue()
    assert (q["dirty"], q["unstable"], q["unknown"]) == (1, 1, 0), q


def test_a_readable_sample_that_LOST_a_PRand_is_not_thrown_away(monkeypatch):
    """THE RULE THE SHRINK GUARD MUST NOT BREAK (#1869 review, both reviewers).

    14 blind PRs, then -- the ordinary event of a PR landing during the ~17 s wait -- 13 PRs
    fully readable. Rejecting every shrink would keep the blind sample, print
    `BLIND(14/14 unread)` and publish ITS action list while a COMPLETE answer was in hand: the
    exact harm this retry exists to remove, manufactured by the retry. So a READABLE answer wins
    -- unless it is EMPTY, which is the degenerate shape the guard is for.
    """
    install(monkeypatch, pr_list=[
        _Result(0, _blind_prs(14)),
        _Result(0, json.dumps([_pr(i, "DIRTY") for i in range(1, 14)]))])
    line = objective.build()
    assert "queue_read=BLIND" not in line, line
    assert "queue_read=SETTLED(samples=2)" in line, line
    assert "nondraft=13" in line, line
    assert "resolve-conflict=13" in line, line


def test_a_FIRST_read_timeout_still_declares_the_fleet_blind(monkeypatch):
    """The classification that `main()`'s cache guard depends on, pinned (#1869 review).

    Absorbing the raise moved this failure off a bare `error=` line (which the guard knows) onto
    `queue=UNREADABLE` (which it does NOT). So the transport classification must be right: a
    FIRST-read timeout is a failure to REACH GitHub and must name the fleet blind -- otherwise the
    failed read is cached and served for up to 900 s (the #6142 class).
    """
    install(monkeypatch)

    def boom(*a, **k):
        raise subprocess.TimeoutExpired(cmd="gh", timeout=120)

    monkeypatch.setattr(objective, "_gh_retry", boom)
    line = objective.build()
    assert "queue=UNREADABLE" in line, line
    assert "gh=UNREADABLE(queue)" in line, line
    assert "error=" not in line, line


def test_the_resample_bounds_the_READ_itself_not_only_its_count(monkeypatch):
    """The two mechanisms that make the wall-clock bound real must not be deletable silently.

    `attempts=1` on a re-read (it is a retry already -- no nested 3 x transport chain) and a
    timeout clipped to the remaining budget. Without either, the worst case returns to
    4 samples x 3 attempts x 120 s, which `run_bounded 90` kills -- and a killed refresh writes
    NO line at all. Asserted on the transport seam, because `install()`'s stub ignores both args.
    """
    install(monkeypatch, pr_list=[_Result(0, _blind_prs(14))])
    real = objective._gh_retry
    calls = []

    def spy(argv, **kw):
        calls.append(kw)
        return real(argv, **kw)

    monkeypatch.setattr(objective, "_gh_retry", spy)
    objective.build()
    assert len(calls) >= 2, calls
    assert calls[0] == {}, calls[0]                       # first read: full transport resilience
    for kw in calls[1:]:
        assert kw.get("attempts") == 1, kw
        assert 0 < kw.get("timeout", 0) <= objective.QUEUE_BLIND_BUDGET_S, kw


def test_a_failed_resample_keeps_the_sample_it_already_has(monkeypatch):
    """Re-reading must not make a transient WORSE than not re-reading.

    The first sample ANSWERED (blind), so a 504 on the second must not collapse the line to
    `queue=UNREADABLE` and throw away `open`/`nondraft`/the DO list.
    """
    install(monkeypatch, pr_list=[_Result(0, _blind_prs(3)),
                                 _Result(1, "", "HTTP 504: Server Error")])
    line = objective.build()
    assert "queue=UNREADABLE" not in line, line
    assert "nondraft=3" in line, line
    assert QUEUE_SEG in line, line
    assert "resample=FAILED" in line, line     # ...and the failure is REPORTED, not silent


def test_a_failed_resample_never_claims_the_fleet_is_blind(monkeypatch):
    """A RE-read failing is not the same fact as the queue being unreadable (#1869 review).

    `queue` is a BLINDING surface, and `gh=UNREADABLE(queue)` is what `main()` keys on to refuse
    the cache write and `turn-classify` keys on to tell every agent to distrust reads. But here
    the queue WAS read and the held sample is on the line -- naming the queue as unreadable both
    misattributes the failure and makes a transient re-read worse than no re-read at all. The
    re-sample surface must therefore be distinctive and non-blinding.
    """
    install(monkeypatch, pr_list=[_Result(0, _blind_prs(3)),
                                 _Result(1, "", "API rate limit exceeded for user ID 1")])
    line = objective.build()
    assert "gh=" not in line, line                      # no fleet-blindness claim
    assert "GH-RATE-LIMITED" not in line, line          # ...and no verdict rewrite
    assert "nondraft=3" in line, line
    assert objective.GH_BLOCKED is None, objective.GH_BLOCKED


def test_a_resample_TIMEOUT_does_not_blank_the_line(monkeypatch):
    """`subprocess.run(timeout=...)` RAISES; it does not return `returncode != 0` (#1869 P1).

    The short re-read timeout makes `TimeoutExpired` the most likely failure on precisely the
    slow-API condition that triggers re-sampling. Uncaught, it escaped `queue()`/`build()` and
    took the held sample, every count, the DO list and the BLIND token with it -- replaced by a
    bare `error=` line, i.e. strictly worse than not re-reading.
    """
    install(monkeypatch, pr_list=[_Result(0, _blind_prs(5))])
    real = objective._gh_retry
    calls = []

    def boom(*a, **k):
        calls.append(1)
        if len(calls) == 1:
            return real(*a, **k)
        raise subprocess.TimeoutExpired(cmd="gh", timeout=1)

    monkeypatch.setattr(objective, "_gh_retry", boom)
    line = objective.build()
    assert "error=" not in line, line
    assert "nondraft=5" in line, line
    assert "queue=UNREADABLE" not in line, line
    assert "resample=FAILED" in line, line
    assert calls == [1, 1], calls          # it did try to re-read, and then stopped


def test_a_mangled_resample_keeps_the_sample_it_already_has(monkeypatch):
    """...and the same rule applies when the transport answered but the BODY was garbage.

    Published as identical: the unparseable branch also returned None, discarding a sample that
    had already parsed -- i.e. a mangled retry was made WORSE than no retry at all.
    """
    install(monkeypatch, pr_list=[_Result(0, _blind_prs(3)),
                                 _Result(0, "<html>502 gateway</html>")])
    line = objective.build()
    assert "queue=UNREADABLE" not in line, line
    assert "nondraft=3" in line, line
    assert "gh=UNREADABLE" not in line, line   # a parse failure is not fleet blindness


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


# --- THE PER-CLASS SEGMENT IS **STATE**, NOT A SECOND DISPATCH LIST (#1872) ---------------
# The beat printed `DO: call-rail=1: #8795 (STUCK 3 beats — land or say why)` while `pr-doctor`
# was running its own pass over the SAME PRs -- two copies of one decision, and the fleet follows
# the instruction instead of the chain (measured 2026-10-16: the PR landed by hand). The counts
# stay, as STATE, and a MONITOR keeps the two things only it can supply: main's health, the
# objective's direction, and the one human gate (`ASK-USER`).

def _stub_queue(monkeypatch, tmp_path, *, nondraft=4, classes=None, by_class=None,
                surface=0, unknown=0, surface_prs=None):
    monkeypatch.setattr(objective, "STATE", str(tmp_path))
    monkeypatch.setattr(objective, "STUCK_FILE", str(tmp_path / "call-rail-stuck.json"))
    monkeypatch.setattr(objective, "main_sha", lambda: SHA)
    monkeypatch.setattr(objective, "main_health", lambda sha: ("GREEN", []))
    monkeypatch.setattr(objective, "ci_critical_path", lambda: (5.0, "test (a)", 6.0))
    monkeypatch.setattr(objective, "queue", lambda: {
        "open": nondraft, "drafts": 0, "nondraft": nondraft, "dirty": 0, "unstable": 0,
        "unknown": unknown, "classes": classes, "by_class": by_class or {},
        "surface": surface, "surface_prs": surface_prs or []})


def test_the_queue_segment_is_labelled_state_and_not_an_instruction(monkeypatch, tmp_path):
    """The label IS the fix: `DO:` named work an automatic chain was already doing."""
    from collections import Counter
    _stub_queue(monkeypatch, tmp_path,
                classes=Counter({"call-rail": 1, "record-review": 2, "running": 1}),
                by_class={"call-rail": [(8795, None)],
                          "record-review": [(8801, None), (8802, None)],
                          "running": [(8806, None)]},
                surface=1, surface_prs=[9001])
    line = objective.build()
    assert "| QUEUE(state; pr-doctor dispatches): " in line, line
    assert "DO: " not in line, line                       # the instruction token is GONE
    # ...the counts and their objects are still REPORTED -- as state
    assert "call-rail=1: #8795" in line, line
    assert "record-review=2: #8801 #8802" in line, line
    # `running` is NAMED, not just counted (#1872 review): a check-run can stay non-completed
    # indefinitely, so a bare `running=2` would let a wedged PR hide behind a number
    assert "running=1: #8806" in line, line
    # ...and the one thing only a human can take still reaches the owner -- WITH its objects
    assert "ASK-USER: surface=1: #9001" in line, line


def test_a_stuck_landable_pr_is_reported_as_a_fact_about_the_dispatcher(monkeypatch, tmp_path):
    """The escalation must not be a second order. What the monitor can add is that a landable PR
    has been landable for N beats and the chain has still not landed it."""
    from collections import Counter
    _stub_queue(monkeypatch, tmp_path, classes=Counter({"call-rail": 1}),
                by_class={"call-rail": [(8795, None)]})
    objective.build()                                     # beat 1: not stuck yet
    line = objective.build()                              # beat 2: one full beat of waiting
    assert "STUCK 2 beats" in line, line
    assert "pr-doctor has not landed it" in line, line
    assert "land or say why" not in line, line            # NOT an order


def test_REGRESSING_still_reaches_the_owner_with_the_new_segment(monkeypatch, tmp_path):
    """The MONITOR half must survive the change: direction over the window is why the token is
    worth waking a human for, and it must not be collateral damage of renaming a label."""
    from collections import Counter
    _stub_queue(monkeypatch, tmp_path, nondraft=21, classes=Counter({"fix-ci": 3}),
                by_class={"fix-ci": [(9, "docs"), (8, "docs"), (7, "python-ci-gate")]})
    line = objective.build(prev=(12, 120.0))
    assert "VERDICT=REGRESSING" in line, line
    assert "| QUEUE(state; pr-doctor dispatches): " in line, line
    assert "IN-PROGRESS: fixing docs=2 python-ci-gate=1" in line, line


def test_a_missing_class_is_not_printed_as_a_zero(monkeypatch, tmp_path):
    """An absent token is honest; a printed zero is a claim. The state segment keeps that rule."""
    from collections import Counter
    _stub_queue(monkeypatch, tmp_path, classes=Counter({"fix-ci": 1, "running": 2}),
                by_class={"fix-ci": [(9, "docs")], "running": [(8, None), (7, None)]})
    line = objective.build()
    assert "call-rail=0" not in line, line
    assert "record-review=0" not in line, line
    assert "running=2" in line, line
