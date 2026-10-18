#!/usr/bin/env python3
"""tools/fleet/outcome_canary.test.py — the acceptance suite for the OUTCOME-LEVEL canary.

WHY A SUITE AND NOT A DEMO
--------------------------
The canary's whole claim is that it fails when the SYSTEM produces nothing. A canary whose own
tests cannot fail is decoration, and this repo has already paid for that lesson twice (an unwired
suite passes by never running; a suite that cannot catch its own defect pins nothing). So:

  * the predicate tests drive the REAL predicates over INJECTABLE fixtures (`tests/fixtures/
    outcome-canary/*.json`), and every fixture declares its own `_expect` — the fixture set is an
    executed claim, not documentation;
  * the SIGNAL tests drive the real CLI end-to-end through `--live --facts … --capture-dir …`, so
    what is asserted is the message that would actually be sent and the exit code that a scheduler
    would actually see;
  * `--mutations` reintroduces each defect this file exists to catch into a TEMP copy of the module
    and requires the paired test to go RED. A mutation whose test still passes is reported as a
    suite FAILURE.

    python3 tools/fleet/outcome_canary.test.py              # green
    python3 tools/fleet/outcome_canary.test.py --mutations  # every mutation, RED
    python3 tools/fleet/outcome_canary.test.py --only a,b   # run named tests
    python3 tools/fleet/outcome_canary.test.py --list

Injected, never guessed:
  OUTCOME_CANARY_MODULE   the module under test (default: ./outcome_canary.py)
  OUTCOME_CANARY_FIXTURES the fixture directory (default: ../../tests/fixtures/outcome-canary)

Zero dependencies: python3 + the standard library. No network, no process table, no clock.
"""

from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import re
import os
import shutil
import subprocess
import sys
import time
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE = os.environ.get("OUTCOME_CANARY_MODULE") or os.path.join(HERE, "outcome_canary.py")
FIXTURES = os.environ.get("OUTCOME_CANARY_FIXTURES") or os.path.normpath(
    os.path.join(HERE, "..", "..", "tests", "fixtures", "outcome-canary"))

TESTS = []


def test(fn):
    TESTS.append((fn.__name__, fn))
    return fn


# ── helpers ─────────────────────────────────────────────────────────────────────────────────────


def load(path=MODULE):
    spec = importlib.util.spec_from_file_location("outcome_canary_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fx(name):
    with open(os.path.join(FIXTURES, name + ".json")) as fh:
        return json.load(fh)


def evaluate_fixture(mod, name, only=None):
    d = fx(name)
    cfg = mod.cfg_from_dict(d.get("config"))
    return dict((v.name, v) for v in mod.evaluate(d["facts"], cfg, only=only))


def statuses(mod, name):
    return dict((k, v.status) for k, v in evaluate_fixture(mod, name).items())


def run_cli(args, module=MODULE, env=None):
    e = dict(os.environ)
    e.update(env or {})
    p = subprocess.run([sys.executable, module] + list(args), capture_output=True, text=True,
                       env=e, timeout=180)
    return p.returncode, p.stdout, p.stderr


def read_capture(d):
    out = {}
    if not os.path.isdir(d):
        return out
    for f in sorted(os.listdir(d)):
        if f.endswith(".txt"):
            with open(os.path.join(d, f)) as fh:
                out[f] = fh.read()
    return out


def assert_raises(fn, what):
    try:
        fn()
    except AssertionError:
        return
    except Exception as exc:
        raise AssertionError("%s raised %s: %s" % (what, type(exc).__name__, exc))
    raise AssertionError(what)


def run_cli(args, module=MODULE, env=None):
    e = dict(os.environ)
    e.update(env or {})
    p = subprocess.run([sys.executable, module] + list(args), capture_output=True, text=True,
                       env=e, timeout=180)
    return p.returncode, p.stdout, p.stderr


def read_capture(d):
    out = {}
    if not os.path.isdir(d):
        return out
    for f in sorted(os.listdir(d)):
        if f.endswith(".txt"):
            with open(os.path.join(d, f)) as fh:
                out[f] = fh.read()
    return out


def assert_raises(fn, what):
    try:
        fn()
    except AssertionError:
        return
    except Exception as exc:
        raise AssertionError("%s raised %s: %s" % (what, type(exc).__name__, exc))
    raise AssertionError(what)


def _code_only(src):
    """The source with comments and string literals removed (kept for the analysis above; the
    launchctl guard uses quoted-form matching because a forbidden token lives INSIDE a literal)."""
    import io
    import tokenize
    keep = []
    for tok in tokenize.generate_tokens(io.StringIO(src).readline):
        if tok.type in (tokenize.STRING, tokenize.COMMENT):
            continue
        keep.append(tok.string)
    return " ".join(keep)




# ════════════════════════════════════════════════════════════════════════════════════════════════
# 1. The predicates — one test per outcome, and per "absent" / "stale" / "unevaluable" variant
# ════════════════════════════════════════════════════════════════════════════════════════════════


@test
def test_healthy_fixture_is_all_pass():
    m = load()
    s = statuses(m, "healthy")
    assert all(v == m.PASS for v in s.values()), s


@test
def test_controller_absent_is_fail_and_is_the_respawn_case():
    m = load()
    v = evaluate_fixture(m, "controller-absent")["controller_cycling"]
    assert v.status == m.FAIL, v
    assert v.variant == "CONTROLLER_ABSENT", v.variant
    assert v.variant in m.RESPAWN_TRIGGERS


@test
def test_controller_alive_with_frozen_log_is_fail_but_not_respawned():
    """The exact shape of "alive but useless" — and it must NOT be respawned (a live controller
    exists; killing/restarting it would destroy whatever it is doing)."""
    m = load()
    v = evaluate_fixture(m, "log-silent")["controller_cycling"]
    assert v.status == m.FAIL, v
    assert v.variant == "LOG_SILENT", v.variant
    assert v.variant not in m.RESPAWN_TRIGGERS
    # and the respawn path itself refuses it
    plan = m.attempt_respawn(v, m.Cfg(), None, dry_run=True)
    assert plan["attempted"] is False and "not absent" in plan["detail"], plan


@test
def test_queue_unreadable_is_fail():
    m = load()
    v = evaluate_fixture(m, "queue-unreadable")["queue_readable"]
    assert (v.status, v.variant) == (m.FAIL, "QUEUE_UNREADABLE"), (v.status, v.variant)


@test
def test_queue_never_read_is_fail_not_pass():
    m = load()
    d = fx("healthy")
    d["facts"]["log_events"]["headers"][0]["queue_token"] = "UNKNOWN"
    cfg = m.cfg_from_dict(d["config"])
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "queue_readable"][0]
    assert (v.status, v.variant) == (m.FAIL, "QUEUE_NEVER_READ"), (v.status, v.variant)


@test
def test_queue_partial_is_fail():
    m = load()
    d = fx("healthy")
    d["facts"]["log_events"]["headers"][0]["queue_token"] = "PARTIAL(P0-blocker)(2m)"
    cfg = m.cfg_from_dict(d["config"])
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "queue_readable"][0]
    assert (v.status, v.variant) == (m.FAIL, "QUEUE_PARTIAL"), (v.status, v.variant)


@test
def test_backlog_empty_out_of_a_large_pool_is_fail():
    m = load()
    v = evaluate_fixture(m, "empty-backlog-large-pool")["queue_readable"]
    assert (v.status, v.variant) == (m.FAIL, "EMPTY_WITH_LARGE_POOL"), (v.status, v.variant)


@test
def test_dispatch_refused_is_fail_not_dispatched():
    """THE headline case: everything above passes, and no work goes out."""
    m = load()
    vs = evaluate_fixture(m, "dispatch-refused")
    assert vs["controller_cycling"].status == m.PASS
    assert vs["queue_readable"].status == m.PASS
    v = vs["work_dispatched"]
    assert (v.status, v.variant) == (m.FAIL, "NOT_DISPATCHED"), (v.status, v.variant)
    assert "could not build claim" in v.evidence, v.evidence


@test
def test_dispatch_gated_is_fail_with_the_gate_named():
    m = load()
    v = evaluate_fixture(m, "dispatch-gated")["work_dispatched"]
    assert (v.status, v.variant) == (m.FAIL, "NO_DISPATCH_GATED"), (v.status, v.variant)
    assert "max_load" in v.evidence


@test
def test_green_while_nothing_merged_is_fail():
    m = load()
    v = evaluate_fixture(m, "no-pr-merged")["pr_merged"]
    assert (v.status, v.variant) == (m.FAIL, "NO_PR_MERGED"), (v.status, v.variant)


@test
def test_gh_unreadable_is_inconclusive_never_green_never_zero():
    m = load()
    vs = evaluate_fixture(m, "gh-unreadable")
    for name in ("pr_created", "pr_merged", "landers"):
        assert vs[name].status == m.INCONCLUSIVE, (name, vs[name].status)
        assert vs[name].variant == "GH_UNREADABLE"


@test
def test_unevaluable_probe_is_inconclusive_not_pass():
    m = load()
    v = evaluate_fixture(m, "headroom-probe-unreadable")["headroom"]
    assert v.status == m.INCONCLUSIVE, v.status


@test
def test_pane_daemon_absent_and_unprotected_are_fails():
    m = load()
    assert evaluate_fixture(m, "daemon-absent")["pane_daemon"].variant == "DAEMON_ABSENT"
    v = evaluate_fixture(m, "daemon-unprotected")["pane_daemon"]
    assert (v.status, v.variant) == (m.FAIL, "PROTECTION_PARTIAL"), (v.status, v.variant)


@test
def test_pane_daemon_alive_without_a_readable_protection_value_is_inconclusive():
    """Alive != protected. On a platform with no oom_score_adj the check is UNPROVEN, not green."""
    m = load()
    v = evaluate_fixture(m, "daemon-protection-unevaluable")["pane_daemon"]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "PROTECTION_UNEVALUABLE"), (v.status, v.variant)


@test
def test_headroom_reports_numbers_on_pass_and_fail():
    m = load()
    ok = evaluate_fixture(m, "healthy")["headroom"]
    assert ok.status == m.PASS and "GiB" in ok.evidence and "MiB" in ok.evidence, ok.evidence
    bad = evaluate_fixture(m, "headroom-low")["headroom"]
    assert bad.status == m.FAIL and "floor" in bad.evidence


@test
def test_lander_expired_is_distinguished_from_never_armed():
    m = load()
    v = evaluate_fixture(m, "lander-expired")["landers"]
    assert (v.status, v.variant) == (m.FAIL, "LANDER_EXPIRED"), (v.status, v.variant)
    # railed PRs are legitimate in rail mode (`--auto` is deliberately not armed)
    d = fx("lander-expired")
    d["facts"]["log_events"]["railed"] = [{"raw": "#900 PENDING (rail mode: auto-merge deliberately "
                                                  "NOT armed)", "pr": 900, "age_s": 100}]
    cfg = m.cfg_from_dict(d["config"])
    v2 = [x for x in m.evaluate(d["facts"], cfg) if x.name == "landers"][0]
    assert v2.status == m.PASS, (v2.status, v2.variant)
    # and a PR that was never armed at all is a different shape
    d2 = fx("lander-expired")
    d2["facts"]["log_events"]["armed"] = []
    cfg2 = m.cfg_from_dict(d2["config"])
    v3 = [x for x in m.evaluate(d2["facts"], cfg2) if x.name == "landers"][0]
    assert v3.variant == "LANDER_MISSING", v3.variant


@test
def test_an_ANCIENT_or_UNAGED_rail_decision_is_not_a_lander():
    """A decision in the log is a decision NOW — and an unaged one is not fresh.

    `#900 PENDING (rail mode …)` printed last night kept a green PR reading "railed" long after the
    rail was abandoned, and an entry carrying no `age_s` (the enclosing cycle header was unparseable,
    so the age is UNKNOWN) was read as fresh. Both are a PASS on a lander that does not exist.
    """
    m = load()

    def grade(entries, bucket="railed"):
        d = fx("lander-expired")
        d["facts"]["log_events"]["armed"] = []
        d["facts"]["log_events"]["railed"] = []
        d["facts"]["log_events"][bucket] = entries
        cfg = m.cfg_from_dict(d["config"])
        return [x for x in m.evaluate(d["facts"], cfg) if x.name == "landers"][0]

    raw = "#900 PENDING (rail mode: auto-merge deliberately NOT armed)"
    fresh = grade([{"raw": raw, "pr": 900, "age_s": 100}])
    assert fresh.status == m.PASS, (fresh.status, fresh.variant, fresh.evidence)

    old = grade([{"raw": raw, "pr": 900, "age_s": 99999}])
    assert old.variant == "LANDER_MISSING", (old.status, old.variant, old.evidence)
    assert "DECISION TOO OLD OR UNAGED (not counted as a lander): [900]" in old.evidence, \
        old.evidence

    unaged = grade([{"raw": raw, "pr": 900}])
    assert unaged.variant == "LANDER_MISSING", (unaged.status, unaged.variant, unaged.evidence)

    # the same rule governs an ARMED decision (the lander-expired fixture's own shape)
    armed_old = grade([{"raw": "#900 auto-armed", "pr": 900, "age_s": 99999}], bucket="armed")
    assert armed_old.variant == "LANDER_MISSING", (armed_old.status, armed_old.variant,
                                                   armed_old.evidence)


@test
def test_rollup_polarity_unknown_and_null_conclusions_are_red():
    """AGENTS.md's rule: only success/neutral/skipped are green, cancelled/stale are non-red, and
    EVERY OTHER CONCLUSION — including an undocumented one and a null one — is RED."""
    m = load()
    assert m.rollup_is_green([{"conclusion": "SUCCESS"}])
    assert m.rollup_is_green([{"conclusion": "success"}, {"conclusion": "skipped"}])
    assert not m.rollup_is_green([])                              # empty is never green
    assert not m.rollup_is_green([{"conclusion": None}])           # in flight is not a pass
    assert not m.rollup_is_green([{"conclusion": "SOMETHING_NEW"}])
    assert not m.rollup_is_green([{"conclusion": "FAILURE"}])


@test
def test_the_rollup_is_graded_on_the_shape_the_LIVE_surface_actually_emits():
    """MEASURED: `gh pr list --json statusCheckRollup` emits
    `__typename, name, workflowName, status, conclusion, startedAt, completedAt, detailsUrl` — no
    `app`, no `id` — so grouping on `app` collapsed every workflow into one check and ranking on `id`
    always fell through to LIST POSITION, which is not chronological (measured: 18 of 59 adjacent
    pairs have a later position with an earlier `startedAt`). `changes` is published by BOTH `CI` and
    `Python CI`, and `ai-review-gate` appears twice with differing conclusions on the same PR: one of
    them decided the PR arbitrarily."""
    m = load()

    def run(**kw):
        e = {"__typename": "CheckRun", "status": "COMPLETED"}
        e.update(kw)
        return e

    ok_ci = run(name="changes", workflowName="CI", conclusion="SUCCESS",
                startedAt="2026-10-18T13:00:00Z")
    bad_py = run(name="changes", workflowName="Python CI", conclusion="FAILURE",
                 startedAt="2026-10-18T13:00:00Z")
    # same NAME, different WORKFLOWS: two checks, and the red one reddens the PR whatever the order
    assert not m.rollup_is_green([ok_ci, bad_py])
    assert not m.rollup_is_green([bad_py, ok_ci])
    # same workflow, two attempts: the NEWER startedAt decides even when the list order says otherwise
    first_red = run(name="ai-review-gate", workflowName="AI Review", conclusion="FAILURE",
                    startedAt="2026-10-18T12:00:00Z")
    rerun_ok = run(name="ai-review-gate", workflowName="AI Review", conclusion="SUCCESS",
                   startedAt="2026-10-18T13:00:00Z")
    assert m.rollup_is_green([rerun_ok, first_red])       # later position is the OLDER attempt
    assert m.rollup_is_green([first_red, rerun_ok])
    # and the newest attempt being RED is red (a re-run that came back red)
    assert not m.rollup_is_green([rerun_ok, dict(first_red, conclusion="FAILURE",
                                                 startedAt="2026-10-18T14:00:00Z")])
    # an attempt IN FLIGHT makes its check unknown, whatever the timestamps say: a queued attempt
    # carries no startedAt at all, so an ordering alone would rank it last and grade the stale green
    in_flight = {"__typename": "CheckRun", "name": "ai-review-gate", "workflowName": "AI Review",
                 "status": "IN_PROGRESS", "conclusion": None}
    assert not m.rollup_is_green([rerun_ok, in_flight])
    assert not m.rollup_is_green([in_flight, rerun_ok])


@test
def test_a_PR_row_that_cannot_be_GRADED_is_UNPROBED_not_silent():
    """`pr.get("probed", True)` read an ABSENT key as `True` (every fixture omitted it), and a row the
    filters could not grade — no mergeability, no check surface — left BOTH `candidates` and
    `unprobed`. An unread PR then vanished from a PASS on the one check that exists to catch a lander
    expiring on a PR nobody looked at."""
    m = load()

    def verdict(rows):
        d = fx("healthy")
        d["facts"]["github"]["open_prs"] = rows
        d["facts"]["github"]["open_pr_count"] = len(rows)   # a payload that agrees with itself
        cfg = m.cfg_from_dict(d["config"])
        return [x for x in m.evaluate(d["facts"], cfg) if x.name == "landers"][0]

    base = {"number": 700, "merge_state_status": "CLEAN", "checks_green": True,
            "auto_armed": True, "draft": False, "probed": True}
    # (a) fully graded + armed: the healthy shape still passes
    v = verdict([dict(base)])
    assert (v.status, v.variant) == (m.PASS, "LANDERS_ARMED"), (v.status, v.variant, v.evidence)
    # (b) `probed` ABSENT: a missing read, so unprobed — never graded
    no_probed = dict(base)
    del no_probed["probed"]
    v = verdict([no_probed])
    assert v.status == m.INCONCLUSIVE and v.variant == "PARTIAL_POPULATION", (v.status, v.variant)
    assert "700" in v.evidence, v.evidence
    # (c) no mergeability value at all
    v = verdict([{"number": 701, "checks_green": True, "auto_armed": True, "draft": False,
                  "probed": True}])
    assert v.variant == "PARTIAL_POPULATION", (v.status, v.variant, v.evidence)
    # (d) a mergeability state this tool does not recognise
    v = verdict([dict(base, number=702, merge_state_status="SOMETHING_NEW")])
    assert v.variant == "PARTIAL_POPULATION", (v.status, v.variant, v.evidence)
    # (e) a KNOWN non-mergeable state is skipped, NOT unprobed: a busy box must not go INCONCLUSIVE
    #     just because PRs are BEHIND or BLOCKED
    v = verdict([dict(base, number=703, merge_state_status="BEHIND"),
                 dict(base, number=704, merge_state_status="BLOCKED")])
    assert v.status == m.PASS and v.variant == "NOTHING_GREEN", (v.status, v.variant, v.evidence)


@test
def test_a_FUTURE_dated_queue_state_or_heartbeat_is_UNKNOWN_not_fresh():
    """The CLOCK_SKEW rule was applied to the log mtime and not to the heartbeat or the queue-state
    file, both of which used `max(0.0, now - ts)` — so a box whose clock runs AHEAD made a stale
    record the freshest possible reading. On the queue-state file that defeats the `queue_stale_s`
    guard whose whole job is to stop a frozen EMPTY read establishing "nothing to do"."""
    m = load()
    now = 1792327664.0
    real_read, real_sh = m.Machine.read_file, m.Machine.sh

    future = int(now + 5 * 3600)
    try:
        m.Machine.read_file = lambda self, path: ("EMPTY %d" % future, None)
        m.Machine.sh = lambda self, cmd: (0, "some-out")
        mc = m.Machine(None)
        mc.controller_paths = []
        cfg = m.Cfg(o_dir="/tmp/x", label="l")
        facts = m.collect_live(cfg, machine=mc, now=now)
    finally:
        m.Machine.read_file, m.Machine.sh = real_read, real_sh
    assert facts["queue_state"]["age_s"] is None, facts["queue_state"]
    assert facts["heartbeat"]["age_s"] is None, facts["heartbeat"]
    # …and that reaches the verdict: an EMPTY read with NO usable age cannot establish emptiness
    d = fx("healthy")
    d["facts"]["log_events"]["headers"] = [{
        "raw": "=== Sun Oct 18 07:47:44 EST 2026 load=4 lanes=0 backlog=0 queue=EMPTY ===",
        "age_s": 60, "ts": now, "backlog": 0, "queue_token": "EMPTY", "lanes": 0}]
    d["facts"]["log_events"]["dispatch_ok"] = []
    d["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "EMPTY %d" % future,
                                 "age_s": None}
    cfg2 = m.cfg_from_dict(d["config"])
    got = dict((x.name, x) for x in m.evaluate(d["facts"], cfg2))
    assert got["work_dispatched"].status == m.INCONCLUSIVE, got["work_dispatched"].as_json()
    assert got["work_dispatched"].variant == "STATE_FROZEN", got["work_dispatched"].variant


@test
def test_static_refuses_a_PARTIAL_expectation_and_a_MISSING_fixture():
    """`_expect: {"headroom": "PASS"}` ran seven checks, asserted one, and printed "every fixture
    matched its declared _expect" with exit 0. And a DELETED fixture removes the outcome it pinned
    while every remaining assertion still passes: the population is part of the pin."""
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-partial-")
    try:
        d = fx("healthy")
        d["_expect"] = {"headroom": "PASS"}
        one = os.path.join(tmp, "healthy.json")
        with open(one, "w") as fh:
            json.dump(d, fh)
        rc, out, err = run_cli(["--static", "--fixture", one, "--json"])
        assert rc == 1, (rc, out[-300:])
        j = json.loads(out)
        assert any(str(x["got"]).startswith("PARTIAL_EXPECT") for x in j["mismatches"]),             j["mismatches"]
        # a directory that no longer holds the outcome-critical fixtures is a mismatch, not a
        # smaller run
        d2 = fx("healthy")
        d2["_expect"] = dict((n, "PASS") for n in m.CHECK_ORDER)
        with open(one, "w") as fh:
            json.dump(d2, fh)
        rc, out, err = run_cli(["--static", "--fixtures-dir", tmp, "--json"])
        assert rc == 1, (rc, out[-300:])
        j = json.loads(out)
        missing = [x["got"] for x in j["mismatches"] if "MISSING_FIXTURE" in str(x["got"])]
        assert len(missing) >= 5, j["mismatches"]
        assert any("lander-expired" in x for x in missing), missing
        # the shipped directory satisfies both rules
        assert m.missing_fixtures(sorted(m.glob.glob(os.path.join(FIXTURES, "*.json")))) == []
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_an_AGE_UNKNOWN_pool_read_is_not_READABLE():
    """The staleness guard fired only for EMPTY, so `queue=READ(223)` written WITHOUT an epoch (the
    bare token the harness emits when `$at` is missing or unparsable) was graded READABLE with the age
    printed as "UNKNOWN": a refresh that stopped writing hours ago, having lost its epoch, read as
    current — and `queue_stale_s`, whose whole job is to stop that, could not fire."""
    m = load()

    def grade(token, qs, backlog=47):
        d = fx("healthy")
        d["facts"]["log_events"]["headers"] = [{
            "raw": "=== Sun Oct 18 07:47:44 EST 2026 load=40 lanes=2 backlog=%d queue=%s ==="
                   % (backlog, token),
            "age_s": 42, "ts": 1792327664, "backlog": backlog, "queue_token": token, "lanes": 2}]
        d["facts"]["log_events"]["dispatch_ok"] = []
        d["facts"]["queue_state"] = qs
        cfg = m.cfg_from_dict(d["config"])
        return dict((x.name, x) for x in m.evaluate(d["facts"], cfg))

    # a bare READ token with an UNREADABLE age: no epoch anywhere ⇒ not current
    got = grade("READ(223)", {"path": "q", "ok": True, "raw": "READ(223)", "age_s": None})
    assert got["queue_readable"].status == m.INCONCLUSIVE, got["queue_readable"].as_json()
    assert got["queue_readable"].variant == "STATE_FROZEN", got["queue_readable"].variant
    assert "no age" in got["queue_readable"].evidence.lower(), got["queue_readable"].evidence
    assert "NO AGE" in got["queue_readable"].detail, got["queue_readable"].detail
    # …and work_dispatched must not bless "nothing to do" on it either (backlog=0 is the shape
    # where "no dispatch" would otherwise be the CORRECT outcome)
    got = grade("READ(223)", {"path": "q", "ok": True, "raw": "READ(223)", "age_s": None},
                backlog=0)
    assert got["work_dispatched"].status == m.INCONCLUSIVE, got["work_dispatched"].as_json()
    assert got["work_dispatched"].variant == "STATE_FROZEN", got["work_dispatched"].variant
    # a KNOWN-fresh READ token is still readable (the conservative direction must not cost this)
    got = grade("READ(223)(9m)", {"path": "q", "ok": True, "raw": "READ(223) 1792327000",
                                  "age_s": 600})
    assert got["queue_readable"].status == m.PASS, got["queue_readable"].as_json()
    # ⛔ A KNOWN-and-OLD READ token is NOT accepted any more. This test used to ASSERT the old trade
    # ("it does say readable, n candidates"), and that trade let a box whose refresh froze three hours
    # ago exit 0 for the WHOLE run while the controller dispatched off a stale `candidates.txt` —
    # #1931 wearing a pass. The reading is legible; the claim is about three hours ago.
    got = grade("READ(223)(6h)", {"path": "q", "ok": True, "raw": "READ(223) 1792300000",
                                  "age_s": 40000})
    assert (got["queue_readable"].status, got["queue_readable"].variant) == (
        m.INCONCLUSIVE, "READABLE_STALE"), got["queue_readable"].as_json()
    assert m.exit_code(list(got.values())) != 0

    # ⛔ and a KNOWN-and-old EMPTY read is STATE_FROZEN, not READABLE_STALE: "the pool is empty" is a
    # POSITIVE claim, and a frozen read cannot support it
    got = grade("EMPTY(6h)", {"path": "q", "ok": True, "raw": "EMPTY", "age_s": 40000}, backlog=0)
    assert (got["queue_readable"].status, got["queue_readable"].variant) == (
        m.INCONCLUSIVE, "STATE_FROZEN"), got["queue_readable"].as_json()


@test
def test_a_MOVING_log_is_not_a_CYCLING_controller():
    """`cycles` was computed, printed and never graded, so a controller wedged mid-cycle read
    PASS/CYCLING for as long as anything else appended to the log — `claim-prune` and the
    `[reap-worker]` lines do, by design. The check's own name is the claim being made."""
    m = load()
    d = fx("healthy")
    d["facts"]["log_events"]["headers"] = []          # the log advances, but no cycle completes
    d["facts"]["log_events"]["dispatch_ok"] = []
    cfg = m.cfg_from_dict(d["config"])
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "controller_cycling"][0]
    assert (v.status, v.variant) == (m.FAIL, "LOG_NO_CYCLE"), (v.status, v.variant, v.evidence)
    assert "0 cycle header(s) inside" in v.evidence, v.evidence


@test
def test_a_payload_that_is_NOT_a_population_is_not_graded():
    """`gh.get("open_prs") or []` turned an ABSENT key into "zero open PRs", and the contradicting
    `open_pr_count` sat in the same dict unread: `landers` asserted "every green PR has an armed
    lander" over a population it never read."""
    m = load()

    def landers(gh):
        d = fx("healthy")
        d["facts"]["github"] = gh
        cfg = m.cfg_from_dict(d["config"])
        return [x for x in m.evaluate(d["facts"], cfg) if x.name == "landers"][0]

    row = {"number": 1, "merge_state_status": "CLEAN", "checks_green": True,
           "auto_armed": True, "draft": False, "probed": True}
    # (a) rows ABSENT, count present: not a population
    v = landers({"ok": True, "open_pr_count": 7})
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "GH_UNREADABLE"), (v.status, v.variant)
    assert "open_prs" in v.evidence, v.evidence
    # (b) count disagrees with the rows: the payload contradicts itself
    v = landers({"ok": True, "open_pr_count": 7, "open_prs": [row]})
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "GH_UNREADABLE"), (v.status, v.variant)
    assert "open_pr_count=7" in v.evidence, v.evidence
    # (c) a coherent payload is still graded
    v = landers({"ok": True, "open_pr_count": 1, "open_prs": [row]})
    assert (v.status, v.variant) == (m.PASS, "LANDERS_ARMED"), (v.status, v.variant, v.evidence)


@test
def test_a_PR_skipped_for_a_KNOWN_reason_is_COUNTED_and_PRINTED():
    """Skipping a BEHIND/DIRTY PR is right; skipping it SILENTLY let `landers` read PASS over a
    population it discarded entirely (measured: every open PR on this box was BLOCKED or DIRTY, so the
    check graded nothing while reporting health)."""
    m = load()
    d = fx("healthy")
    d["facts"]["github"] = {"ok": True, "open_pr_count": 3, "open_prs": [
        {"number": 900, "merge_state_status": "CLEAN", "checks_green": True, "auto_armed": True,
         "draft": False, "probed": True},
        {"number": 901, "merge_state_status": "BEHIND", "checks_green": True, "auto_armed": False,
         "draft": False, "probed": True},
        {"number": 902, "merge_state_status": "CLEAN", "checks_green": False, "auto_armed": False,
         "draft": False, "probed": True},
    ]}
    cfg = m.cfg_from_dict(d["config"])
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "landers"][0]
    assert v.status == m.PASS, (v.status, v.variant, v.evidence)
    assert "skipped (known, not landable): 2" in v.evidence, v.evidence
    assert "901:BEHIND" in v.evidence and "902:red" in v.evidence, v.evidence


@test
def test_a_review_decision_that_is_NOT_recognised_is_UNPROBED_not_dropped():
    """The `review_decision` filter dropped a FULLY GRADED row into neither `candidates` nor
    `unprobed`: a green, mergeable, unarmed PR read as "no lander is expected". A known decision
    (CHANGES_REQUESTED, REVIEW_REQUIRED, DISMISSED) is skipped and printed; an unknown one abstains."""
    m = load()

    def landers(rd):
        d = fx("healthy")
        d["facts"]["github"] = {"ok": True, "open_pr_count": 1, "open_prs": [
            {"number": 910, "merge_state_status": "CLEAN", "checks_green": True,
             "auto_armed": False, "draft": False, "probed": True, "review_decision": rd}]}
        cfg = m.cfg_from_dict(d["config"])
        return [x for x in m.evaluate(d["facts"], cfg) if x.name == "landers"][0]

    v = landers("CHANGES_REQUESTED")
    assert v.status == m.PASS, (v.status, v.variant, v.evidence)
    assert "910:CHANGES_REQUESTED" in v.evidence, v.evidence
    v = landers("SOMETHING_NEW")
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "PARTIAL_POPULATION"), (v.status, v.variant)
    assert "910" in v.evidence, v.evidence
    # and the healthy shape is untouched: an APPROVED, green, unarmed PR is still a lander failure
    v = landers("APPROVED")
    assert (v.status, v.variant) == (m.FAIL, "LANDER_MISSING"), (v.status, v.variant, v.evidence)


@test
def test_a_PARTIAL_run_cannot_exit_0():
    """`--only headroom` evaluated one check, printed "summary: 1 PASS · 0 FAIL · 0 INCONCLUSIVE →
    exit 0" and exited 0 while seven outcomes were unprobed — the contract this tool states about
    itself. The unevaluated checks are now named, and the exit code is 2 (never 0)."""
    m = load()
    rc, out, err = run_cli(["--static", "--fixture", os.path.join(FIXTURES, "healthy.json")])
    assert rc == 0, (rc, out[-300:])
    d = fx("healthy")
    facts = os.path.join(tempfile.mkdtemp(prefix="oc-partial-run-"), "f.json")
    with open(facts, "w") as fh:
        json.dump(d, fh)
    rc, out, err = run_cli(["--live", "--facts", facts, "--json", "--dry-run", "--no-notify",
                            "--only", "headroom", "--controller-ws",
                            "00000000-0000-0000-0000-0000000000c1"])
    j = json.loads(out)
    assert j["exit"] == 2, (j["exit"], j.get("not_evaluated"))
    assert set(j["not_evaluated"]) == set(m.CHECK_ORDER) - {"headroom"}, j["not_evaluated"]
    assert len(j["verdicts"]) == 1, j["verdicts"]
    # a FAIL among the evaluated checks still wins: 1, not 2
    dr = os.path.join(os.path.dirname(facts), "dr.json")
    with open(dr, "w") as fh:
        json.dump(fx("dispatch-refused"), fh)
    rc, out, err = run_cli(["--live", "--facts", dr, "--json", "--dry-run", "--no-notify",
                            "--only", "work_dispatched", "--controller-ws",
                            "00000000-0000-0000-0000-0000000000c1"])
    assert json.loads(out)["exit"] == 1, out[-300:]


@test
def test_a_usage_error_is_exit_3_not_the_inconclusive_code():
    """argparse exits 2 on a usage error and 2 is the INCONCLUSIVE code: a caller dispatching on the
    documented codes read `--bogusflag` as "the fleet is inconclusive"."""
    m = load()
    rc, out, err = run_cli(["--bogusflag"])
    assert rc == 3, (rc, err[-200:])
    rc, out, err = run_cli([])                    # no mode at all
    assert rc == 3, (rc, err[-200:])


@test
def test_an_ok_gh_surface_with_NO_COUNT_is_UNREAD_not_a_measured_zero():
    """`isinstance(n, int) and n > 0` sends `None` into the FAIL branch, so a payload that ANSWERED
    but carries no `prs_created_in_window` produced `FAIL/NO_PR_CREATED` — asserting the fleet
    "opened no PR in 3.0h" off a field that was never read, and printing `PRs created: None` beside
    it. The headroom arm already enforces this rule ("an `ok` read with no number is not 0 GiB");
    a FAIL on this check must mean one was MEASURED."""
    m = load()
    cfg = m.cfg_from_dict({})
    for name, fn, key in (("pr_created", m.check_pr_created, "prs_created_in_window"),
                          ("pr_merged", m.check_pr_merged, "prs_merged_in_window")):
        gh = {"ok": True, "source": "rest", "open_pr_count": 9, "open_prs": []}
        v = fn({"github": gh}, cfg)
        assert (v.status, v.variant) == (m.INCONCLUSIVE, "GH_COUNT_UNREAD"), (name, v.status, v.variant)
        assert key in v.evidence, v.evidence
        # …and the same surface WITH the count still grades normally (the guard cannot swallow it)
        gh[key] = 4 if name == "pr_created" else 0
        gh["open_pr_count"] = 0
        v2 = fn({"github": gh}, cfg)
        assert v2.variant != "GH_COUNT_UNREAD", (name, v2.variant)


@test
def test_a_PR_opened_and_CLOSED_UNMERGED_still_counts_as_CREATED():
    """The created population was built from the OPEN list plus the MERGED list, and
    `_collect_rest` drops `closed`-without-`merged_at` rows before the counter sees them — so a
    fleet that opened work and superseded it read `FAIL/NO_PR_CREATED` ("opened no PR in 3.0h")
    while the closed page held the PRs it opened."""
    m = load()
    cfg = m.cfg_from_dict({"pr_window_s": 10800.0})
    now = 1792327664.0
    iso = m._iso(now - 600)
    closed_unmerged = {"number": 11, "createdAt": iso, "mergedAt": None}
    merged = {"number": 12, "createdAt": iso, "mergedAt": iso}
    open_row = {"number": 13, "createdAt": iso, "mergedAt": None}
    out = {}
    m._fill_counts(out, [open_row], [merged], cfg, now,
                   also_created=[closed_unmerged, merged, open_row])
    assert out["prs_created_in_window"] == 3, out
    # ⛔ and a row that appears in BOTH populations is counted ONCE (the closed page contains the
    # merged rows too, so double counting would inflate the created count by the merge count)
    out2 = {}
    m._fill_counts(out2, [open_row], [merged], cfg, now, also_created=[merged, merged])
    assert out2["prs_created_in_window"] == 2, out2
    # without the closed page the same world reads 1 — this is the count that used to be graded
    out3 = {}
    m._fill_counts(out3, [open_row], [merged], cfg, now)
    assert out3["prs_created_in_window"] == 2, out3


@test
def test_the_report_DISCLOSES_every_input_that_changes_a_verdict():
    """`--live --json` never disclosed `queue_stale_s`, the input that produces STATE_FROZEN, so two
    runs with `--queue-stale-min 90` and `--queue-stale-min 0` emitted byte-identical config blocks
    while grading the same record differently. Its docstring also called the block "the subset a
    FIXTURE may declare", which was wrong in both directions (`cfg_from_dict` accepts every
    default)."""
    m = load()
    a = m.cfg_from_dict({"queue_stale_s": 90.0, "window_s": 60.0})
    b = m.cfg_from_dict({"queue_stale_s": 0.0, "window_s": 60.0})
    assert a.as_json() != b.as_json(), (a.as_json(), b.as_json())
    assert a.as_json()["queue_stale_s"] == 90.0, a.as_json()
    # ⛔ NOT `and k in a.as_json()` — that guard is vacuous for exactly the key that is missing, so
    # deleting `window_s`, `pr_window_s` or `rest_probe_max` from the report survived the suite.
    # Every scalar input must be DISCLOSED, whether or not it is there today.
    missing = [k for k, v in m.Cfg.DEFAULTS.items()
               if isinstance(v, (int, float, str)) and k not in a.as_json()]
    assert not missing, "undisclosed verdict inputs: %s" % (missing,)
    for k, v in m.Cfg.DEFAULTS.items():
        if isinstance(v, (int, float, str)):
            assert a.as_json()[k] == getattr(a, k), (k, a.as_json()[k])


@test
def test_the_pr_created_evidence_names_the_counts_it_prints():
    """The labels and the values were crossed (`open=` printed the merged count and `merged=` the open
    count), so a PASS's evidence contradicted `pr_merged`'s block two checks later."""
    m = load()
    d = fx("healthy")
    d["facts"]["github"]["open_pr_count"] = 24
    d["facts"]["github"]["prs_merged_in_window"] = 13
    d["facts"]["github"]["prs_created_in_window"] = 3
    d["facts"]["github"]["open_prs"] = d["facts"]["github"]["open_prs"] or []
    cfg = m.cfg_from_dict(d["config"])
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "pr_created"][0]
    assert "open=24 merged=13" in v.evidence, v.evidence


@test
def test_a_flaky_re_run_reads_GREEN_rather_than_red():
    """The rollup is a list of ATTEMPTS, not a list of checks. A job that failed and then passed on
    re-run appears TWICE, so a flat "every entry must be green" walk reads that commit RED — and a
    red-reading green PR silently leaves the `landers` population, which is a false green on the one
    check that exists to catch a lander expiring on a PR nobody looked at. (A re-run ADDS a red; it
    does not clear one.)
    """
    m = load()
    gh_a = {"slug": "github-actions"}      # a REST-shaped surface: it carries `app` and `id`
    ok = {"app": gh_a, "name": "build", "conclusion": "SUCCESS", "id": 20}
    bad = {"app": gh_a, "name": "build", "conclusion": "FAILURE", "id": 10}
    assert m.rollup_is_green([bad, ok])              # newest attempt (highest id) is the one graded
    assert m.rollup_is_green([ok, bad])              # ... and list ORDER is not the ordering
    # an id-less surface (status context) falls back to list position, the only order it has
    assert m.rollup_is_green([{"context": "cla", "state": "FAILURE"},
                              {"context": "cla", "state": "SUCCESS"}])
    # a newer FAILURE on the same check is red: the newest attempt decides, not the newest green
    assert not m.rollup_is_green([ok, dict(bad, id=40)])
    # a different check that is red still reddens the PR
    assert not m.rollup_is_green([bad, ok, {"app": gh_a, "name": "lint",
                                            "conclusion": "FAILURE", "id": 30}])
    # a check with no conclusion is IN FLIGHT, and in flight is not a pass
    assert not m.rollup_is_green([bad, ok, {"app": gh_a, "name": "build",
                                            "conclusion": None, "id": 50}])
    # a legacy status context carries `state`, not `conclusion` — reading only `conclusion` graded
    # every one of them RED and dropped that PR from the lander population
    assert m.rollup_is_green([{"context": "cla", "state": "SUCCESS"}])
    assert not m.rollup_is_green([{"context": "cla", "state": "PENDING"}])
    assert not m.rollup_is_green([{"context": "cla", "state": "FAILURE"}])


@test
def test_a_PR_with_NO_check_surface_is_UNPROBED_not_dropped_from_the_lander_population():
    """`rollup_is_green` answers None for "there is no check surface to read" (a path-filtered
    workflow, a fork PR awaiting approval, a repo with no required checks). Grading that `False` while
    `probed` derived from mergeability alone put the PR in NEITHER `candidates` NOR `unprobed`, so a
    CLEAN, APPROVED, UNARMED PR produced PASS/NOTHING_GREEN and exit 0 — the exact silent expiry the
    check exists for. Both collectors must mark it UNPROBED."""
    m = load()
    assert m.rollup_is_green([]) is None          # NO SURFACE READ — not "red", not "green"
    assert m.rollup_is_green(None) is None
    assert m.rollup_is_green([{"conclusion": "FAILURE"}]) is False

    real = m._run_gh

    def fake(argv):
        j = " ".join(argv)
        if j.endswith("--json") or "pr list" in j:
            if "--state closed" in j:
                return 0, "[]"
            return 0, json.dumps([{                                  # CLEAN + APPROVED, no checks
                "number": 4242, "mergeStateStatus": "CLEAN", "autoMergeRequest": None,
                "isDraft": False, "statusCheckRollup": [], "reviewDecision": "APPROVED",
                "createdAt": "2026-10-18T03:00:00Z", "mergedAt": None}])
        return 0, "[]"

    try:
        m._run_gh = fake
        gh = m.collect_github("o/r", m.Cfg(), now=1792327664.0)
    finally:
        m._run_gh = real
    assert gh["ok"] is True, gh
    row = gh["open_prs"][0]
    assert row["checks_green"] is None, row
    assert row["probed"] is False, row           # …so it reaches PARTIAL_POPULATION, not silence

    facts = fx("healthy")["facts"]
    facts["github"] = gh
    cfg = m.cfg_from_dict(fx("healthy")["config"])
    v = [x for x in m.evaluate(facts, cfg) if x.name == "landers"][0]
    assert v.status == m.INCONCLUSIVE, (v.status, v.variant, v.evidence)
    assert v.variant == "PARTIAL_POPULATION", v.variant
    assert "4242" in v.evidence, v.evidence


@test
def test_a_process_that_MENTIONS_the_daemon_is_not_the_daemon():
    """The unscoped-substring defect the controller census was fixed for, three times over, was still
    open in the pane census: `tail -f ~/.cmux/cmux-tui.out` and `less …/cmux-tui.log` counted as the
    daemon — processes an operator creates by following this check's own NEXT COMMAND — and because
    the fleet deprioritises lanes they inherit a negative oom_score_adj, so a machine with NO daemon
    read PASS/ALIVE_PROTECTED."""
    m = load()
    ps = "\n".join([
        "  72496 /Applications/cmux.app/Contents/MacOS/cmux-tui",
        "  76777 /usr/local/bin/cmux-tui --no-color",
        "  905 tail -f /Users/x/.cmux/cmux-tui.out",
        "  906 less /Users/x/.cmux/logs/cmux-tui.log",
        "  907 /bin/zsh -c less /Users/x/.cmux/cmux-tui.log",
        "  908 node /opt/homebrew/lib/node_modules/cmux/cmux-tui serve",
        "  909 ps -Ao pid=,command=",
    ])
    pids, near = m.pick_pane_daemon_pids(ps)
    assert [r["pid"] for r in pids] == [72496, 76777, 908], pids
    # 909 is the probe's OWN `ps` line: it does not mention the daemon, so it is not even a candidate
    assert sorted(n["pid"] for n in near) == [905, 906, 907], near

    facts = fx("healthy")["facts"]
    facts["pane"] = {"ok": True, "cmd": "cmux-tui", "protection_supported": True,
                     "protection_source": "oom_score_adj",
                     "pids": [], "near_misses": near}
    cfg = m.cfg_from_dict(fx("healthy")["config"])
    v = [x for x in m.evaluate(facts, cfg) if x.name == "pane_daemon"][0]
    assert v.status == m.FAIL, (v.status, v.variant)
    assert v.variant == "DAEMON_ABSENT", v.variant
    assert "905" in v.evidence, v.evidence        # what was REJECTED is evidence


@test
def test_an_EMPTY_gh_response_is_a_failed_read_not_zero_PRs():
    """`json.loads(txt or "[]")` turned a gh that exited 0 with NO output (a wrapper that swallows
    stdout, a truncated pipe) into "zero PRs": collect_github returned ok=True and `landers` PASSed
    over a population it never read. `_gh_empty()` exists to forbid exactly that."""
    m = load()
    assert m._json_list("") is None and m._json_list("   ") is None
    assert m._json_obj("") is None
    assert m._json_list("[]") == []               # a real empty list still parses
    real = m._run_gh
    try:
        m._run_gh = lambda argv: (0, "")
        gh = m.collect_github("o/r", m.Cfg(), now=1792327664.0)
    finally:
        m._run_gh = real
    assert gh["ok"] is False, gh                  # NOT ok=True with zero PRs
    facts = fx("healthy")["facts"]
    facts["github"] = gh
    cfg = m.cfg_from_dict(fx("healthy")["config"])
    got = dict((v.name, (v.status, v.variant)) for v in m.evaluate(facts, cfg))
    for name in ("pr_created", "pr_merged", "landers"):
        assert got[name] == (m.INCONCLUSIVE, "GH_UNREADABLE"), (name, got[name])


@test
def test_a_TRUNCATED_check_run_page_is_not_a_green_rollup():
    """The REST check-runs read is bounded at per_page=100 and the bound was never surfaced, though
    `total_count` was in hand and the PR-list bound is a verdict input (`page_full`). A red run past
    page one made the page-one read `True` and the PR LANDERS_ARMED on a commit that is not green."""
    m = load()
    real = m._run_gh

    def fake(argv):
        j = " ".join(argv)
        if "pulls?state=open" in j:
            return 0, json.dumps([{"number": 900, "draft": False, "auto_merge": {"x": 1},
                                   "mergeable_state": "clean", "head": {"sha": "a" * 40}}])
        if "pulls?state=closed" in j:
            return 0, "[]"
        if "check-runs" in j:
            # 102 runs exist; the page holds one, and it is GREEN — the red one is past the bound
            return 0, json.dumps({"total_count": 102,
                                  "check_runs": [{"conclusion": "success", "name": "ci"}]})
        return 0, json.dumps({"mergeable_state": "clean", "head": {"sha": "a" * 40}})

    try:
        m._run_gh = fake
        gh = m.collect_github("o/r", m.Cfg(), now=1792327664.0)
    finally:
        m._run_gh = real
    assert gh["ok"] is True and gh["source"] == "rest", gh.get("source")
    row = gh["open_prs"][0]
    assert row["checks_green"] is None, row       # TRUNCATED is not green
    assert row["probed"] is False, row
    assert "TRUNCATED" in " ".join(gh.get("detail_errors") or []), gh.get("detail_errors")


@test
def test_the_header_timezone_is_USED_so_a_remote_cell_is_not_graded_in_local_time():
    """The tz token was matched and dropped, with the rest read as LOCAL time. A PST cell read from
    an EST box reported a 5-minute-old event as 4h05m old, so its `#N auto-armed` line fell out of the
    window and a green ARMED PR read LANDER_MISSING — the silent-expiry verdict, falsely."""
    m = load()
    base = "Sun Oct 18 07:44:14 %s 2026"
    est, pst = m.parse_cycle_ts(base % "EST"), m.parse_cycle_ts(base % "PST")
    assert est is not None and pst is not None
    # 07:44 PST is 3h LATER than 07:44 EST in absolute time: the token decides, not this machine's clock
    assert pst - est == 3 * 3600, (est, pst)
    # an absolute conversion, not this machine's zone: 07:44:14 EST is 12:44:14 UTC
    assert est == m.calendar.timegm((2026, 10, 18, 12, 44, 14, 0, 1, -1)), est
    # numeric offsets are accepted too (a `date` with a format string prints these)
    assert m.parse_cycle_ts(base % "+0200") == m.parse_cycle_ts(base % "CEST")
    # an UNKNOWN token falls back to the local reading rather than being guessed at
    assert m.parse_cycle_ts(base % "QZT") == m.time.mktime((2026, 10, 18, 7, 44, 14, 0, 1, -1))


@test
def test_a_dry_run_does_NOT_persist_the_default_notification_state():
    """`--dry-run` says "report only: never send, never respawn" and it still SAVED the state file —
    clearing a delivered key, which re-arms an alert already sent so the next real poll stacks a
    SECOND brief, and writing a `last_status` of all-PASS the box does not have."""
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-drystate-")
    try:
        facts = os.path.join(tmp, "f.json")
        with open(facts, "w") as fh:
            json.dump(fx("dispatch-refused"), fh)
        # (a) a bare --dry-run must not write the DEFAULT state file
        default = os.path.join(tmp, "default", "state.json")
        rc, out, err = run_cli(["--live", "--facts", facts, "--json", "--dry-run",
                                "--controller-ws", "00000000-0000-0000-0000-0000000000c1"],
                               env={"OUTCOME_CANARY_STATE": default})
        j = json.loads(out)
        assert j["signal"]["state_persisted"] is False, j["signal"]
        assert not os.path.exists(default), "a preview wrote the default state file"
        # …and a PRE-EXISTING default state (a delivered key) is left byte-identical, so an alert
        # already sent is not silently re-armed into a second brief on the next real poll
        os.makedirs(os.path.dirname(default))
        with open(default, "w") as fh:
            json.dump({"version": 1, "boxes": {"local": {"notified": {
                "work_dispatched|NOT_DISPATCHED": {"at": 1, "delivered": True}}}}}, fh)
        before = open(default).read()
        rc, out, err = run_cli(["--live", "--facts", facts, "--json", "--dry-run",
                                "--controller-ws", "00000000-0000-0000-0000-0000000000c1"],
                               env={"OUTCOME_CANARY_STATE": default})
        assert open(default).read() == before, "a preview rewrote the state it only read"
        # (b) a caller who NAMES a destination (--state / --capture-dir) may write there: that is the
        # same rule the capture path already follows, and it keeps de-duplication testable
        rc, out, err = run_cli(_live_facts_args(tmp, "dispatch-refused",
                                                os.path.join(tmp, "s.json"),
                                                os.path.join(tmp, "cap")))
        j = json.loads(out)
        assert j["signal"]["state_persisted"] is True, j["signal"]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_a_box_run_does_not_grade_against_THIS_machines_repo():
    """`_repo_from_plist` opens the LOCAL LaunchAgents plist, so a `--box` run graded a remote cell
    against whichever cell this machine happens to run — a healthy fleet reported for a repo nobody
    is working on. Reading the box's plist is not plumbed, so an unnamed repo must abstain."""
    m = load()
    a = m.build_parser().parse_args(["--live", "--box", "cell-2"])
    cfg = m.cfg_from_args(a)
    assert cfg.repo == "", cfg.repo              # not this machine's repo, and not a guess
    facts = fx("healthy")["facts"]
    facts["github"] = m.collect_github("", cfg)  # …which makes the three PR checks abstain
    got = dict((v.name, v.status) for v in m.evaluate(facts, cfg))
    for name in ("pr_created", "pr_merged", "landers"):
        assert got[name] == m.INCONCLUSIVE, (name, got[name])
    a2 = m.build_parser().parse_args(["--live", "--box", "cell-2", "--repo", "o/r"])
    assert m.cfg_from_args(a2).repo == "o/r"


@test
def test_an_UNPARSEABLE_header_is_reported_as_unparseable_not_as_absent():
    """`unparsed_headers` was counted and never read, so the evidence said "none in the parsed log
    tail" while the log held N headers — a false statement about the world that reads exactly like
    "the loop wrote nothing"."""
    m = load()
    d = fx("healthy")
    d["facts"]["log_events"]["headers"] = []
    d["facts"]["log_events"]["unparsed_headers"] = 5
    cfg = m.cfg_from_dict(d["config"])
    got = dict((x.name, x) for x in m.evaluate(d["facts"], cfg))
    v = got["queue_readable"]
    assert v.variant == "NO_REFRESH", v.variant
    assert "5 header(s) present but UNPARSEABLE" in v.evidence, v.evidence
    # …and the SAME datum, because "no cycle in the window" is a claim about the log there too
    d2 = fx("healthy")
    d2["facts"]["log_events"]["headers"] = []
    d2["facts"]["log_events"]["dispatch_ok"] = []
    d2["facts"]["log_events"]["unparsed_headers"] = 5
    cfg2 = m.cfg_from_dict(d2["config"])
    w = [x for x in m.evaluate(d2["facts"], cfg2) if x.name == "work_dispatched"][0]
    assert w.variant == "NO_CYCLE_IN_WINDOW", (w.variant, w.evidence)
    assert "5 header(s) present but UNPARSEABLE" in w.evidence, w.evidence


@test
def test_a_genuinely_EMPTY_pool_is_IDLE_and_the_report_SAYS_idle():
    """The one branch that grants PASS for the ABSENCE of a dispatch (`IDLE_EMPTY_POOL`) was asserted
    by no fixture and no test, and its variant — the only thing separating "work moved" from "nothing
    to do" — was unpinned: mutating the variant to `DISPATCHED` survived every gate, so a report line
    reading "work dispatched" for a fleet that dispatched nothing was unfalsifiable."""
    m = load()
    d = fx("healthy")
    d["facts"]["log_events"]["headers"] = [{
        "raw": "=== Sun Oct 18 07:47:44 EST 2026 load=4 lanes=0 backlog=0 queue=EMPTY(1m) ===",
        "age_s": 60, "ts": 1792327664, "backlog": 0, "queue_token": "EMPTY(1m)", "lanes": 0}]
    d["facts"]["log_events"]["dispatch_ok"] = []
    d["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "EMPTY", "age_s": 60.0}
    cfg = m.cfg_from_dict(d["config"])
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "work_dispatched"][0]
    assert (v.status, v.variant) == (m.PASS, "IDLE_EMPTY_POOL"), (v.status, v.variant, v.evidence)
    # …and the fixture that ships with it must agree, through the real CLI
    rc, out, err = run_cli(["--static", "--fixture",
                            os.path.join(FIXTURES, "idle-empty-pool.json")])
    assert rc == 0, (rc, out[-300:], err[-300:])


@test
def test_log_parser_reads_both_measured_header_formats():
    m = load()
    a = "=== Sun Oct 18 07:47:44 EST 2026 load=40 lanes=2 backlog=47 queue=READ(223)(9m) ==="
    b = "=== Sun 18 Oct 2026 07:36:20 EST load=40 lanes=0 backlog=42 queue=READ(237)(6h) ==="
    ev = m.parse_log([a, "[dispatch] load=40 lanes=2 -> 4601 4602", b], now=1792327664 + 60)
    assert len(ev["headers"]) == 2, ev["headers"]
    assert ev["unparsed_headers"] == 0
    h0 = ev["headers"][0]
    assert (h0["backlog"], h0["lanes"], h0["queue_token"]) == (47, 2, "READ(223)(9m)"), h0
    assert ev["headers"][1]["backlog"] == 42
    ok = ev["dispatch_ok"][0]
    assert ok["issues"] == [4601, 4602], ok
    # the dispatch line inherits its enclosing header's timestamp (the log prints no per-line ts)
    assert ok["ts"] == h0["ts"], (ok["ts"], h0["ts"])
    assert ok["age_s"] == 60


@test
def test_log_parser_marks_an_unparseable_header_and_fails_closed():
    m = load()
    ev = m.parse_log(["=== not a date at all load=40 lanes=2 backlog=4 queue=READ(4) ===",
                      "[dispatch] load=40 lanes=2 -> 1"], now=1.0)
    assert ev["headers"] == [] and ev["unparsed_headers"] == 1, ev
    # no timestamp => no age => the dispatch line can never be graded fresh
    assert ev["dispatch_ok"][0]["age_s"] is None


@test
def test_queue_token_vocabulary_is_the_refresh_own():
    m = load()
    assert m.parse_queue_token("EMPTY(12s)")["kind"] == "EMPTY"
    assert m.parse_queue_token("READ(223)(9m)")["pool"] == 223
    assert m.parse_queue_token("READ(223)(9h)")["token_age_s"] == 9 * 3600.0
    assert m.parse_queue_token("PARTIAL(P0-blocker)(2m)")["partial"] == "P0-blocker"
    assert m.parse_queue_token("UNREADABLE")["kind"] == "UNREADABLE"
    assert m.parse_queue_token("READING")["kind"] == "UNPARSEABLE"


@test
def test_controller_census_rejects_a_wrapper_that_merely_mentions_the_script():
    """The measured false population: a `bash -c` job whose TEXT mentions orch-loop.sh is not a
    controller. Matching the substring produced "6 controllers for 3 cells"."""
    m = load()
    blobby = ("  95105     1 /bin/bash -c export PATH=x; cd ~/Documents/GitHub/tortoise; "
              "echo \"  Mac controller: $(pgrep -f 'orchestrator/orch-loop.sh')\"")
    real = "  22947 24792 /bin/bash /Users/me/orchestrator/orch-loop.sh"
    parent = "  22561     1 /bin/bash /Users/me/orchestrator/orch-loop.sh"
    got, near = m.pick_controller_pids("\n".join([blobby, real, parent]),
                                       ["/Users/me/orchestrator/orch-loop.sh"])
    pids = [r["pid"] for r in got]
    assert [r["pid"] for r in near] == [95105], near
    assert 95105 not in pids, pids
    assert set(pids) == {22947, 22561}, pids
    assert got[0]["pid"] == 22947, "the DEEPEST process must be reported first"


# ════════════════════════════════════════════════════════════════════════════════════════════════
# 2. The SIGNAL, end-to-end through the real CLI
# ════════════════════════════════════════════════════════════════════════════════════════════════


def _live_facts_args(tmp, fixture_name, state, capture):
    facts = os.path.join(tmp, "facts-%s.json" % fixture_name)
    with open(facts, "w") as fh:
        json.dump(fx(fixture_name), fh)
    # An explicit --controller-ws keeps the suite off `cmux workspace list`: the suite must run in
    # CI and on a box with no cmux, and workspace DISCOVERY is not what these tests are about.
    return ["--live", "--facts", facts, "--state", state, "--capture-dir", capture,
            "--controller-ws", "00000000-0000-0000-0000-0000000000c1", "--json",
            # ⛔ THE SUITE MUST NOT TOUCH A REAL CONTROLLER. Without a dry run, `controller-absent`
            # fixtures made `attempt_respawn` run `launchctl kickstart -k <the live label>` on the
            # machine running the tests, then poll up to 40s. A test that can restart the fleet it is
            # testing is worse than a flaky test: it is an action with a real side effect.
            # `--dry-run` still reports the PLAN (which is what (a) asserts); (c) additionally passes
            # --no-respawn to assert the suppression path.
            "--dry-run"]


@test
def test_failing_run_produces_a_message_and_a_non_zero_exit():
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-fail-")
    try:
        state = os.path.join(tmp, "state.json")
        cap = os.path.join(tmp, "cap")
        rc, out, err = run_cli(_live_facts_args(tmp, "dispatch-refused", state, cap))
        assert rc == 1, (rc, err[-800:])
        msgs = read_capture(cap)
        assert len(msgs) == 1, list(msgs)
        body = list(msgs.values())[0]
        # the four things a message MUST carry, or it is not a signal
        assert "work_dispatched" in body, body
        assert "NOT_DISPATCHED" in body, body
        assert "could not build claim" in body, body                       # the evidence line
        assert "orchestrator-harness/README.md" in body and "§" in body     # orientation + SECTION
        assert "NEXT COMMAND" in body and "$O/logs/orch-loop.log" in body   # the next command
        j = json.loads(out)
        assert j["exit"] == 1
        got = [s["check"] for s in j["signal"]["sent"]]
        assert got == ["work_dispatched"], got
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_passing_run_produces_no_message_and_exit_zero():
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-pass-")
    try:
        state = os.path.join(tmp, "state.json")
        cap = os.path.join(tmp, "cap")
        rc, out, err = run_cli(_live_facts_args(tmp, "healthy", state, cap))
        assert rc == 0, (rc, err[-800:])
        assert read_capture(cap) == {}, "a passing run must not notify"
        j = json.loads(out)
        assert j["signal"]["sent"] == [] and j["signal"]["not_delivered"] == []
        assert all(v["status"] == "PASS" for v in j["verdicts"]), j["verdicts"]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_notifier_deduplicates_on_unchanged_state():
    """One message per state CHANGE, not one per poll. The second identical run speaks once."""
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-dedupe-")
    try:
        state = os.path.join(tmp, "state.json")
        cap1, cap2 = os.path.join(tmp, "cap1"), os.path.join(tmp, "cap2")
        rc1, out1, _ = run_cli(_live_facts_args(tmp, "dispatch-refused", state, cap1))
        assert rc1 == 1
        assert len(read_capture(cap1)) == 1
        rc2, out2, _ = run_cli(_live_facts_args(tmp, "dispatch-refused", state, cap2))
        assert rc2 == 1, "dedupe suppresses the MESSAGE, never the exit code"
        assert read_capture(cap2) == {}, "the second run must not send the same state again"
        j = json.loads(out2)
        assert j["signal"]["suppressed"] == ["work_dispatched|NOT_DISPATCHED"], j["signal"]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_a_recovery_rearms_the_alert():
    """A PASS clears the key, so a RE-BREAK after a recovery speaks again. Otherwise the alert fires
    once for the first outage of the day and stays silent for every one after it."""
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-rearm-")
    try:
        state = os.path.join(tmp, "state.json")
        cap_a = os.path.join(tmp, "a")
        rc, _, _ = run_cli(_live_facts_args(tmp, "dispatch-refused", state, cap_a))
        assert rc == 1 and len(read_capture(cap_a)) == 1
        cap_ok = os.path.join(tmp, "ok")
        rc, _, _ = run_cli(_live_facts_args(tmp, "healthy", state, cap_ok))
        assert rc == 0 and read_capture(cap_ok) == {}
        cap_b = os.path.join(tmp, "b")
        rc, _, _ = run_cli(_live_facts_args(tmp, "dispatch-refused", state, cap_b))
        assert rc == 1 and len(read_capture(cap_b)) == 1, "a re-break must speak again"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_respawn_is_planned_only_when_the_controller_is_genuinely_absent():
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-respawn-")
    try:
        state = os.path.join(tmp, "state.json")
        # (a) ABSENT -> a launchctl plan is produced, kickstart first, and never a `-w` form
        rc, out, err = run_cli(_live_facts_args(tmp, "controller-absent", state,
                                                os.path.join(tmp, "c1")) + ["--dry-run"])
        j = json.loads(out)
        rr = j["signal"]["respawn"]
        assert rr is not None, (rc, err[-500:])
        assert rr["attempted"] is False and "would run" in rr["detail"], rr
        assert "launchctl kickstart -k" in rr["detail"], rr["detail"]
        # (b) ALIVE but silent -> no respawn is planned at all
        rc, out, err = run_cli(_live_facts_args(tmp, "log-silent", state,
                                                os.path.join(tmp, "c2")) + ["--dry-run"])
        j = json.loads(out)
        assert j["signal"]["respawn"] is None, j["signal"]["respawn"]
        assert "--no-respawn" not in err
        # (c) and with --no-respawn even the absent case is suppressed
        rc, out, err = run_cli(_live_facts_args(tmp, "controller-absent", state,
                                                os.path.join(tmp, "c3")) + ["--dry-run",
                                                                            "--no-respawn"])
        j = json.loads(out)
        assert j["signal"]["respawn"]["attempted"] is False
        assert "suppressed" in j["signal"]["respawn"]["detail"], j["signal"]["respawn"]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_inconclusive_only_run_exits_2_not_0():
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-incon-")
    try:
        state = os.path.join(tmp, "state.json")
        rc, out, err = run_cli(_live_facts_args(tmp, "gh-unreadable", state,
                                                os.path.join(tmp, "c")) + ["--no-notify"])
        assert rc == 2, (rc, err[-500:])
        j = json.loads(out)
        assert j["exit"] == 2
        assert all(v["status"] != "PASS" for v in j["verdicts"]
                   if v["check"] in ("pr_created", "pr_merged", "landers")), j["verdicts"]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_refused_delivery_is_not_recorded_as_sent_so_the_next_poll_retries():
    """A dry run resolves the workspace but cannot deliver. The state must NOT record it, or the
    canary would go silent having told nobody."""
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-undelivered-")
    try:
        state = os.path.join(tmp, "state.json")
        facts = os.path.join(tmp, "f.json")
        with open(facts, "w") as fh:
            json.dump(fx("dispatch-refused"), fh)
        rc, out, err = run_cli(["--live", "--facts", facts, "--state", state, "--json",
                                "--dry-run", "--controller-ws", "00000000-0000-0000-0000-000000000000"])
        j = json.loads(out)
        assert j["signal"]["sent"] == [], j["signal"]["sent"]
        assert len(j["signal"]["not_delivered"]) == 1, j["signal"]
        assert "DRY-RUN" in j["signal"]["not_delivered"][0]["detail"]
        with open(state) as fh:
            st = json.load(fh)
        notified = st["boxes"]["local"]["notified"]
        assert notified == {}, notified
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_stat_probe_reads_both_shapes_and_rejects_prose():
    """⛔ GNU `stat -f %m FILE` does NOT fail — on Linux it prints a six-line FILESYSTEM block whose
    last line is the epoch. Reading `stat -f` first made every Linux box report the log MISSING
    (found by review, reproduced in ubuntu:24.04), which fails controller_cycling with LOG_MISSING
    and blinds both log checks."""
    m = load()
    assert m.parse_stat_mtime("1792328709") == 1792328709            # BSD `stat -f %m`
    assert m.parse_stat_mtime("1792328709\n") == 1792328709          # GNU `stat -c %Y`
    gnu_fs_block = ('  File: "/etc/hostname"\n    ID: 1f9faa3bb8e516e9 Namelen: 255  Type: btrfs\n'
                    'Block size: 4096  Fundamental block size: 4096\n'
                    'Blocks: Total: 100 Inodes: Total: 0  Free: 0\n1792328709')
    assert m.parse_stat_mtime(gnu_fs_block) == 1792328709            # GNU `-f` filesystem mode
    assert m.parse_stat_mtime("") is None
    assert m.parse_stat_mtime("stat: cannot statx 'x': No such file") is None
    assert m.parse_stat_mtime("MISSING") is None


@test
def test_collector_parses_the_emitter_literal_lines():
    """The fixtures supply ALREADY-PARSED events, so they prove the predicates and never the
    collector. These are the literal strings orch-loop.sh writes — a `skipped` line was measured at
    223 occurrences in a 6000-line tail with 0 parsed, and the parenthetical refusal form was
    dropped from the count entirely."""
    m = load()
    lines = [
        "=== Sun Oct 18 07:47:44 EST 2026 load=40 lanes=2 backlog=47 queue=READ(223)(9m) ===",
        "[dispatch] load=40 lanes=2 -> 4601 4602 ",
        "[dispatch] #4725 NOT dispatched — could not build claim commit",
        "[dispatch] #1620 NOT dispatched (claim infra error) — the claim commit this box may "
        "have pushed WAS released",
        "[dispatch] skipped (swap_free=387M<=min_swap_free=600M) lanes=9 workers=0",
        "[dispatch] backlog empty queue=READ(223)(4m)",
        "#8880 auto-armed",
        "#8881 PENDING (rail mode: auto-merge deliberately NOT armed — arming it would bypass the rail)",
    ]
    ev = m.parse_log(lines, now=1792327664 + 60)
    assert len(ev["dispatch_ok"]) == 1 and ev["dispatch_ok"][0]["issues"] == [4601, 4602]
    ref = ev["dispatch_refused"]
    assert len(ref) == 2, ref
    assert ref[0]["reason"] == "could not build claim commit", ref[0]
    assert ref[1]["reason"].startswith("(claim infra error)"), ref[1]
    sk = ev["dispatch_skipped"]
    assert len(sk) == 1 and sk[0]["why"] == "swap_free=387M<=min_swap_free=600M", sk
    assert len(ev["dispatch_empty"]) == 1 and len(ev["armed"]) == 1 and len(ev["railed"]) == 1


@test
def test_unreadable_process_table_is_inconclusive_and_never_respawns():
    """An unreadable `ps` used to read as `pids: []` — i.e. as ABSENCE, the one state that respawns.
    On a box at load 130 a timed-out `ps` would then `kickstart -k` a healthy controller."""
    m = load()
    d = fx("controller-absent")
    d["facts"]["controller"] = {"ok": False, "pids": [], "error": "TimeoutExpired: 120s"}
    cfg = m.cfg_from_dict(d["config"])
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "controller_cycling"][0]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "PROCESS_TABLE_UNREADABLE"), (v.status, v.variant)
    assert v.variant not in m.RESPAWN_TRIGGERS
    assert "processes matching orch-loop.sh: 0" not in v.evidence, \
        "an unreadable read must not be reported as zero processes"


@test
def test_respawn_abstains_when_a_controller_appeared_after_the_facts():
    """The facts were collected seconds-to-minutes ago. With KeepAlive a controller can come back in
    that window, and the action must re-measure AT THE MOMENT OF ACTION (fleet rule) rather than
    trust a verdict it already knows can be stale. `kickstart -k` on a live controller kills work."""
    m = load()

    class FakeMachine(object):
        remote = False
        box = "local"

        def __init__(self):
            self.ran = []

        def snapshot_controller(self):
            return {"ok": True, "pids": [{"pid": 4242}]}

        def log_age(self):
            return 5.0

        def log_stat(self):
            return {"exists": True, "mtime": 1000, "age_s": 5.0}

        def sh_argv(self, argv, timeout=None):
            self.ran.append(argv)
            return 0, ""

    fm = FakeMachine()
    v = m.V("controller_cycling", m.FAIL, "CONTROLLER_ABSENT", "e")
    rr = m.attempt_respawn(v, m.Cfg(), fm, dry_run=False, poll_deadline_s=0.1)
    assert rr["attempted"] is False, rr
    assert "appeared" in rr["detail"], rr["detail"]
    assert fm.ran == [], "no launchctl command may run against a live controller"

    class BlindMachine(object):
        """`ps` timed out at load 130 — the collector's ok:False abstention, in the ACTION path."""
        remote = False
        box = "local"

        def __init__(self):
            self.ran = []

        def snapshot_controller(self):
            return {"ok": False, "pids": [], "error": "TimeoutExpired: ps"}

        def log_age(self):
            return None

        def log_stat(self):
            return {"exists": True, "mtime": None, "age_s": None}

        def sh_argv(self, argv, timeout=None):
            self.ran.append(argv)
            return 0, ""

    bm = BlindMachine()
    rr = m.attempt_respawn(v, m.Cfg(), bm, dry_run=False, poll_deadline_s=0.1)
    assert rr["attempted"] is False, rr
    assert "could not be read" in rr["detail"], rr["detail"]
    assert bm.ran == [], "an unreadable process table must never trigger kickstart"


@test
def test_respawn_requires_the_log_to_ADVANCE_not_merely_be_recent():
    """`after.age_s < 120` is satisfied by a log written BEFORE the attempt (the crashed-then-KeepAlive
    case), so a respawn that restarted nothing read as a proven recovery. Proof is an ADVANCE."""
    m = load()
    v = m.V("controller_cycling", m.FAIL, "CONTROLLER_ABSENT", "e")

    class Stuck(object):
        """A pid appears after kickstart (so the ONLY thing that can distinguish took from
        did-not-take is whether the log ADVANCED), and the log never moves."""
        remote = False
        box = "local"

        def __init__(self):
            self.n = 0

        def snapshot_controller(self):
            self.n += 1
            return {"ok": True, "pids": ([{"pid": 99}] if self.n > 1 else [])}

        def log_stat(self):
            # the log is 30s old and NEVER moves: recent, but not advancing
            return {"exists": True, "mtime": 1000, "age_s": 30.0}

        def sh_argv(self, argv, timeout=None):
            return 0, ""

    rr = m.attempt_respawn(v, m.Cfg(), Stuck(), dry_run=False, poll_deadline_s=1.0)
    assert rr["attempted"] is True, rr
    assert rr["took"] is False, rr

    class Advancing(Stuck):
        def __init__(self):
            Stuck.__init__(self)
            self.n = 0

        def log_stat(self):
            self.n += 1
            return {"exists": True, "mtime": 1000 + self.n, "age_s": 0.0}

        def snapshot_controller(self):
            return {"ok": True, "pids": ([{"pid": 99}] if self.n > 1 else [])}

    rr = m.attempt_respawn(v, m.Cfg(), Advancing(), dry_run=False, poll_deadline_s=5.0)
    assert rr["took"] is True, rr


@test
def test_a_zero_oom_score_adj_is_not_protection():
    """`0` is EVERY process's default: only a NEGATIVE value deprioritises it. `<= 0` made the arm
    that must fire on "cmux-tui was OOM-killed while the unit read active" permanently green."""
    m = load()
    base = fx("healthy")
    for adj, want in ((0, m.FAIL), (500, m.FAIL), (-1000, m.PASS), (-300, m.PASS)):
        d = json.loads(json.dumps(base))
        d["facts"]["pane"]["pids"][0]["oom_score_adj"] = adj
        cfg = m.cfg_from_dict(d["config"])
        v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "pane_daemon"][0]
        assert v.status == want, (adj, v.status, v.variant)
    d = json.loads(json.dumps(base))
    d["facts"]["pane"]["pids"] = [{"pid": 1, "oom_score_adj": 0}]
    cfg = m.cfg_from_dict(d["config"])
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "pane_daemon"][0]
    assert (v.status, v.variant) == (m.FAIL, "PROTECTION_ABSENT"), (v.status, v.variant)


@test
def test_a_future_dated_event_is_unknown_never_fresh():
    """A `--live --box` run against a cell in another timezone: the header is parsed as LOCAL time
    while `now` is the canary's epoch, so a UTC cell read from UTC-5 yields a NEGATIVE age for an
    event minutes old — and a negative age passes every `age > window` staleness test as FRESH."""
    m = load()
    hdr = "=== Sun Oct 18 07:47:44 EST 2026 load=12 lanes=1 backlog=3 queue=READ(9)(1m) ==="
    ts = m.parse_ts_field(m.RE_HEADER.match(hdr).group("body"))
    assert m.parse_cycle_ts(m.RE_HEADER.match(hdr).group("body").split(" load=")[0]) == ts
    assert ts is not None, hdr
    # the canary's epoch is 5h BEHIND the cell's wall clock (a UTC cell read from UTC-5)
    ev = m.parse_log([hdr, "[dispatch] load=12 lanes=1 -> 4242"], now=ts - 5 * 3600)
    assert ev["dispatch_ok"][0]["age_s"] is None, ev["dispatch_ok"][0]
    assert ev["headers"][0]["age_s"] is None, ev["headers"][0]
    d = fx("healthy")
    d["facts"]["log_events"]["dispatch_ok"] = [dict(ev["dispatch_ok"][0]) if ev["dispatch_ok"] else
                                              {"raw": "[dispatch] load=12 lanes=1 -> 4242",
                                               "issues": [4242], "issue_count": 1, "age_s": None}]
    cfg = m.cfg_from_dict(d["config"])
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "work_dispatched"][0]
    assert v.status != m.PASS, (v.status, v.variant, v.evidence)


@test
def test_a_bash_c_wrapper_ending_in_the_script_path_is_not_a_controller():
    """Measured on this box: a leftover `bash -c tail -f /dev/null; : …/O/orch-loop.sh` matched a
    tail-anchored regex, so a DEAD fleet read as cycling and the ABSENT state that owns the respawn
    was never reached (5 "controllers" for one)."""
    m = load()
    P = "/Users/danielospina/orchestrator/orch-loop.sh"
    real = ("22947 1 /bin/bash %s\n"
            "72361 1 bash -c tail -f /dev/null; : %s\n"     # a STRING ending in the right path
            "72362 1 /bin/bash -lc exec %s\n"                # a combined short option
            % (P, P, P))
    pids, near = m.pick_controller_pids(real, [P])
    assert [p["pid"] for p in pids] == [22947], pids
    assert sorted(p["pid"] for p in near) == [72361, 72362], near


@test
def test_the_census_requires_a_shell_invocation():
    """`/usr/bin/env bash <path>` is a real way to start something that is not the controller: the
    argv[0] shell check is what rejects it, and it is the only conjunct that can."""
    m = load()
    P = "/Users/me/orchestrator/orch-loop.sh"
    ps = (" 22947 1 /bin/bash %s\n"
          "   600 1 /usr/bin/env bash %s\n"      # a non-shell argv[0] holding the right path
          "   601 1 python3 %s\n" % (P, P, P))
    rows, near = m.pick_controller_pids(ps, [P])
    assert [r["pid"] for r in rows] == [22947], rows
    assert sorted(r["pid"] for r in near) == [600, 601], near


@test
def test_the_census_is_scoped_to_THIS_cell_and_reports_what_it_rejected():
    """Measured 2026-10-18: two leaked test-fixture processes
    (`…/T/fleet-inventory-test.*/O/orch-loop.sh`) satisfied "a controller exists", so the census read
    3 controllers for 1 real one — a false PASS on controller_cycling, and a respawn that refused to
    act because the only live pids were stubs. The supervisor scopes to `$O/orch-loop.sh`; this is a
    consumer of that rule, not a second verdict."""
    m = load()
    ps = ("  9915     1 bash /var/folders/x/T/fleet-inventory-test.abc/O/orch-loop.sh\n"
          " 22947 24792 /bin/bash /Users/me/orchestrator/orch-loop.sh\n"
          " 36539     1 bash /var/folders/x/T/bringup-test.def/a/O/orch-loop.sh\n"
          "  500 1 /bin/bash -lc exec ./orch-loop.sh\n"          # a combined short option
          "  501 1 /bin/bash /Users/me/orchestrator/orch-loop.sh --issue 12\n")  # takes no args
    rows, near = m.pick_controller_pids(ps, ["/Users/me/orchestrator/orch-loop.sh"])
    assert [r["pid"] for r in rows] == [22947], rows
    assert sorted(r["pid"] for r in near) == [500, 501, 9915, 36539], near


@test
def test_capture_never_writes_the_default_state_path():
    """A preview must not silence the alert: `--capture-dir` records deliveries, so writing the
    DEFAULT state file marks a failure "notified" that nobody was told about, and the next real run
    suppresses it. The capture run's state lives inside the capture dir."""
    m = load()

    class A(object):
        pass

    a = A()
    a.o_dir = None
    a.box = "local"
    a.repo = "o/r"
    a.label = None
    a.window_min = a.pr_window_min = a.mem_floor_mb = a.disk_floor_gb = None
    a.pool_threshold = None
    a.controller_ws = None
    a.state_path = None
    a.capture_dir = os.path.join(tempfile.mkdtemp(prefix="oc-cap-"), "cap")
    cfg = m.cfg_from_args(a)
    assert cfg.state_path.startswith(os.path.abspath(a.capture_dir)), cfg.state_path
    assert cfg.state_path != m.default_state_path(), cfg.state_path


@test
def test_an_ambiguous_send_is_not_blind_retried_but_a_refusal_is():
    """safe-send.sh: rc 3 (REFUSED) means nothing was consumed, so a retry is free; rc 1/4 mean the
    bytes may already be in the composer, and its own comment says "Do NOT blind-retry (that stacks
    a second instruction)". Retrying an ambiguous send every poll stacks duplicate instructions."""
    m = load()
    v = m.V("work_dispatched", m.FAIL, "NOT_DISPATCHED", "e")
    st = m.State(os.path.join(tempfile.mkdtemp(prefix="oc-amb-"), "s.json"), "local")
    assert m._send_rc_is_ambiguous(m.SAFE_SEND_RC[1]) is True
    assert m._send_rc_is_ambiguous(m.SAFE_SEND_RC[4]) is True
    assert m._send_rc_is_ambiguous(m.SAFE_SEND_RC[3]) is False
    st.mark_ambiguous(v.key, 1.0)
    to_send, suppressed = m.plan_notifications([v], st, "local", "iso", 2.0)
    assert to_send == [] and [x.key for x in suppressed] == [v.key], (to_send, suppressed)
    # a DIFFERENT shape re-arms automatically, because the key carries the variant
    v2 = m.V("work_dispatched", m.FAIL, "NO_DISPATCH", "e")
    to_send, _ = m.plan_notifications([v2], st, "local", "iso", 2.0)
    assert [x.key for x, _ in to_send] == [v2.key], to_send
    # …and when v2 is DELIVERED the stale marker for v1 must go with it, or a return to v1 is
    # suppressed by an attempt recorded for a shape that no longer exists.
    st.clear_others("work_dispatched", keep=v2.key)
    st.mark(v2.key, 2.0, delivered=True)
    assert st.is_ambiguous(v.key) is False, "a delivered sibling must clear the stale marker"
    to_send, _ = m.plan_notifications([v], st, "local", "iso", 3.0)
    assert [x.key for x, _ in to_send] == [v.key], ("a return to the first shape went silent", to_send)


@test
def test_a_FROZEN_pool_read_is_not_a_current_one():
    """The refresh appends the age to the token for exactly one reason: "a value frozen by a dead
    refresh cannot pass as a fresh one". The age was parsed and never read, so `queue=EMPTY(6h)` with
    backlog=0 PASSed both queue checks and the whole run exited 0 on a six-hour-old reading."""
    m = load()
    d = fx("healthy")
    d["facts"]["log_events"]["headers"] = [{
        "raw": "=== Sun Oct 18 07:47:44 EST 2026 load=12 lanes=1 backlog=0 queue=EMPTY(6h) ===",
        "age_s": 60, "ts": 0, "backlog": 0, "queue_token": "EMPTY(6h)"}]
    d["facts"]["log_events"]["dispatch_ok"] = []
    d["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "EMPTY",
                                 "age_s": 6 * 3600.0}
    cfg = m.cfg_from_dict(d["config"])
    got = dict((v.name, v) for v in m.evaluate(d["facts"], cfg))
    assert (got["queue_readable"].status, got["queue_readable"].variant) == (
        m.INCONCLUSIVE, "STATE_FROZEN"), (got["queue_readable"].status,
                                          got["queue_readable"].variant)
    assert "EMPTY" in got["queue_readable"].evidence, got["queue_readable"].evidence
    assert got["work_dispatched"].status == m.INCONCLUSIVE, (
        got["work_dispatched"].status, got["work_dispatched"].variant)
    assert got["work_dispatched"].variant == "STATE_FROZEN", got["work_dispatched"].variant
    # a stale EMPTY read must not let the whole run report green
    assert m.exit_code(list(got.values())) in (1, 2), m.exit_code(list(got.values()))

    # ⛔ …and NOR does a stale NON-EMPTY read. This leg used to assert PASS ("it does say readable, n
    # candidates"), reasoning that a FAIL would cry wolf on a healthy box (measured: READ(223)(57m)
    # while two issues had been dispatched 101s earlier). The reasoning was right about FAIL and wrong
    # about PASS: the honest answer is neither — ABSTAIN. INCONCLUSIVE cries no wolf (it accuses no
    # one, and `work_dispatched` reports the dispatches it can actually see) and it is not green on a
    # six-hour-old pool number the controller may still be dispatching off.
    d3 = fx("healthy")
    d3["facts"]["log_events"]["headers"] = [{
        "raw": "=== Sun Oct 18 07:47:44 EST 2026 load=12 lanes=1 backlog=33 queue=READ(223)(6h) ===",
        "age_s": 60, "ts": 0, "backlog": 33, "queue_token": "READ(223)(6h)"}]
    d3["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "READ(223)", "age_s": 6 * 3600.0}
    cfg3 = m.cfg_from_dict(d3["config"])
    got3 = dict((v.name, v) for v in m.evaluate(d3["facts"], cfg3))
    assert (got3["queue_readable"].status, got3["queue_readable"].variant) == (
        m.INCONCLUSIVE, "READABLE_STALE"), (got3["queue_readable"].variant)
    assert m.exit_code(list(got3.values())) != 0

    # a CURRENT read of the same shape is still the documented PASS
    d2 = fx("healthy")
    d2["facts"]["log_events"]["headers"] = [{
        "raw": "=== Sun Oct 18 07:47:44 EST 2026 load=12 lanes=1 backlog=0 queue=EMPTY(1m) ===",
        "age_s": 60, "ts": 0, "backlog": 0, "queue_token": "EMPTY(1m)"}]
    d2["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "EMPTY", "age_s": 60.0}
    cfg2 = m.cfg_from_dict(d2["config"])
    got2 = dict((v.name, v) for v in m.evaluate(d2["facts"], cfg2))
    assert got2["queue_readable"].status == m.PASS, got2["queue_readable"].variant


@test
def test_an_EMPTY_read_with_NO_age_is_not_a_current_read():
    """The harness EMITS an unaged token (a torn or hand-edited state file prints the bare token), and
    its own comment calls such a record "a stale flag waiting to be read as current". The staleness
    guard returned None for an UNKNOWN age, so `EMPTY` with no age was graded CURRENT."""
    m = load()
    d = fx("healthy")
    d["facts"]["log_events"] = {
        "headers": [{"raw": "=== Sun Oct 18 07:47:44 EST 2026 load=12 lanes=1 queue=EMPTY ===",
                     "age_s": 60, "ts": 0, "backlog": 0, "queue_token": "EMPTY"}],
        "dispatch_ok": [], "dispatch_refused": [], "dispatch_empty": [], "dispatch_skipped": [],
        "armed": [], "railed": []}
    d["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "EMPTY", "age_s": None}
    cfg = m.cfg_from_dict(d["config"])
    got = dict((v.name, v) for v in m.evaluate(d["facts"], cfg))
    assert (got["queue_readable"].status, got["queue_readable"].variant) == (
        m.INCONCLUSIVE, "STATE_FROZEN"), (got["queue_readable"].status, got["queue_readable"].variant)
    assert "UNKNOWN (no age)" in got["queue_readable"].evidence, got["queue_readable"].evidence
    assert got["work_dispatched"].variant == "STATE_FROZEN", got["work_dispatched"].variant
    assert m.exit_code(list(got.values())) != 0


@test
def test_the_staleness_limit_is_CONFIGURABLE_and_actually_applies():
    """`--queue-stale-min` was advertised in the CLI help and the doc but absent from Cfg.FIELDS, so
    both the flag and a fixture's `config.queue_stale_s` were silently discarded — an inert setting."""
    m = load()
    assert m.Cfg(queue_stale_s=600).queue_stale_s == 600.0
    assert m.Cfg(queue_stale_s=600.0).queue_stale_s == 600.0
    d = fx("healthy")
    d["facts"]["log_events"] = {
        "headers": [{"raw": "=== Sun Oct 18 07:47:44 EST 2026 load=12 lanes=1 queue=EMPTY(2m) ===",
                     "age_s": 60, "ts": 0, "backlog": 0, "queue_token": "EMPTY(2m)"}],
        "dispatch_ok": [], "dispatch_refused": [], "dispatch_empty": [], "dispatch_skipped": [],
        "armed": [], "railed": []}
    d["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "EMPTY", "age_s": 120.0}
    # the default (90m) tolerates a 2-minute-old read …
    got = dict((v.name, v) for v in m.evaluate(d["facts"], m.cfg_from_dict(d["config"])))
    assert got["queue_readable"].status == m.PASS, got["queue_readable"].variant
    # … and a 60-second limit, which only works if FIELDS carries the field, flips it
    d["config"]["queue_stale_s"] = 60.0
    got2 = dict((v.name, v) for v in m.evaluate(d["facts"], m.cfg_from_dict(d["config"])))
    assert got2["queue_readable"].variant == "STATE_FROZEN", got2["queue_readable"].variant


@test
def test_a_ZERO_staleness_limit_means_NO_tolerance_not_unset():
    """`x or DEFAULT` treats 0 as unset — and 0 is the value that expresses maximum strictness. A 30
    minute old EMPTY record then passed both queue checks while the operator had asked for zero
    tolerance, and a fixture pinning `queue_stale_s: 0` asserted nothing."""
    m = load()
    d = fx("healthy")
    d["facts"]["log_events"] = {
        "headers": [{"raw": "=== Sun Oct 18 07:47:44 EST 2026 load=12 lanes=1 queue=EMPTY(30m) ===",
                     "age_s": 60, "ts": 0, "backlog": 0, "queue_token": "EMPTY(30m)"}],
        "dispatch_ok": [], "dispatch_refused": [], "dispatch_empty": [], "dispatch_skipped": [],
        "armed": [], "railed": []}
    d["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "EMPTY", "age_s": 1800.0}
    d["config"]["queue_stale_s"] = 0
    cfg = m.cfg_from_dict(d["config"])
    assert cfg.queue_stale_s == 0.0, cfg.queue_stale_s
    got = dict((v.name, v) for v in m.evaluate(d["facts"], cfg))
    assert got["queue_readable"].variant == "STATE_FROZEN", got["queue_readable"].variant
    assert got["work_dispatched"].variant == "STATE_FROZEN", got["work_dispatched"].variant
    # a zero limit must not make a CURRENT read fail either: age 0 is inside "any age is stale"? No —
    # zero tolerance means every non-zero age is stale, and a same-instant read is the boundary.
    d["facts"]["queue_state"]["age_s"] = 0.0
    d["facts"]["log_events"]["headers"][0]["queue_token"] = "EMPTY(0s)"
    got2 = dict((v.name, v) for v in m.evaluate(d["facts"], m.cfg_from_dict(d["config"])))
    assert got2["queue_readable"].status == m.PASS, got2["queue_readable"].variant


@test
def test_a_future_dated_log_mtime_is_UNKNOWN_not_the_freshest_possible():
    """`max(0.0, now - mtime)` turned a clock-skewed cell's log into the freshest possible one, so
    "pid alive but the log stopped" — the state that must fire — read PASS, and since absence is the
    only respawn trigger nothing was raised."""
    m = load()

    class Fwd(object):
        remote = False
        box = "local"
        log_path = "/x/log"
        tail_lines = 10

        def sh(self, cmd, timeout=None):
            if cmd.startswith("stat"):
                # 30 minutes in the FUTURE
                return 0, "%d\n" % (time.time() + 1800)
            if cmd.startswith("tail"):
                return 0, ""
            return 0, "YES"

    log, lines, err = m.Machine.read_log(Fwd(), "/x/log")
    assert log["exists"] is True and log["age_s"] is None, log
    assert "FUTURE" in (log.get("error") or ""), log

    facts = fx("healthy")["facts"]
    facts["log"] = {"path": "/x/log", "exists": True, "age_s": None,
                    "error": "log mtime is 1800s in the FUTURE (clock skew)"}
    cfg = m.cfg_from_dict(fx("healthy")["config"])
    v = [x for x in m.evaluate(facts, cfg) if x.name == "controller_cycling"][0]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "LOG_UNREADABLE"), (v.status, v.variant)


@test
def test_a_fixture_with_no_expect_asserts_nothing_and_says_so():
    """An EMPTY assertion set is not "all zero assertions satisfied": a new fixture with a misspelt
    `_expects` key contributed no coverage while the runner printed success and exited 0."""
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-noexpect-")
    try:
        d = fx("healthy")
        d.pop("_expect", None)
        bad = os.path.join(tmp, "noexpect.json")
        with open(bad, "w") as fh:
            json.dump(d, fh)
        rc, out, err = run_cli(["--static", "--fixture", bad, "--json"])
        assert rc == 1, (rc, out[-300:])
        j = json.loads(out)
        assert j["mismatches"] and j["mismatches"][0]["got"] == "NO_EXPECT", j["mismatches"]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_a_truncated_open_PR_population_is_not_a_population():
    """A PR beyond page one is in neither `candidates` nor `unprobed`, so `landers` would speak for a
    population it never saw. Only the per-PR probe bound used to be reported."""
    m = load()
    d = fx("healthy")
    prs = [{"number": n, "merge_state_status": "BLOCKED", "checks_green": False,
            "auto_armed": False, "draft": False, "probed": True} for n in range(1, 101)]
    d["facts"]["github"]["open_prs"] = prs
    d["facts"]["github"]["open_pr_count"] = len(prs)
    d["facts"]["github"]["page_full"] = True
    cfg = m.cfg_from_dict(d["config"])
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "landers"][0]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "PARTIAL_POPULATION"), (v.status, v.variant)
    assert "TRUNCATED" in v.evidence, v.evidence


@test
def test_landers_grades_REST_shaped_rows():
    """REST spells mergeability LOWERCASE ("clean"). Comparing it to "CLEAN" dropped every REST-probed
    PR from `candidates` while leaving probed=True, so it appeared in neither the candidates NOR the
    unprobed list and `landers` said PASS/NOTHING_GREEN over zero graded PRs — on exactly the surface
    the REST fallback exists for. The collector boundary must normalise, and "not known yet" must be
    UNPROBED rather than invisible."""
    m = load()
    real = m._run_gh

    def fake(argv):
        if "pulls?state=open" in " ".join(argv):
            return 0, json.dumps([
                {"number": 900, "draft": False, "auto_merge": None,          # green, unarmed
                 "mergeable_state": "clean", "head": {"sha": "a" * 40}},
                {"number": 901, "draft": False, "auto_merge": {"x": 1},      # green, armed
                 "mergeable_state": "clean", "head": {"sha": "b" * 40}},
                {"number": 902, "draft": False, "auto_merge": None,          # mergeability UNKNOWN
                 "mergeable_state": "unknown", "head": {"sha": "c" * 40}},
            ])
        if "pulls?state=closed" in " ".join(argv):
            return 0, "[]"
        if "check-runs" in " ".join(argv):
            return 0, json.dumps({"check_runs": [{"conclusion": "success"}]})
        mm = re.search(r"/pulls/(\d+)$", " ".join(argv))
        if mm:
            state = {"900": "clean", "901": "clean", "902": "unknown"}[mm.group(1)]
            return 0, json.dumps({"mergeable_state": state, "head": {"sha": mm.group(1) * 10}})
        return 0, "{}"

    try:
        m._run_gh = fake
        gh = m.collect_github("o/r", m.Cfg(), now=1000000.0)
    finally:
        m._run_gh = real
    assert gh["ok"] is True and gh["source"] == "rest", gh.get("source")
    rows = dict((r["number"], r) for r in gh["open_prs"])
    assert rows[900]["merge_state_status"] == "CLEAN", rows[900]      # normalised, not dropped
    assert rows[900]["probed"] is True, rows[900]
    assert rows[902]["probed"] is False, rows[902]                    # UNKNOWN is unprobed, not void

    facts = fx("healthy")["facts"]
    facts["github"] = gh
    cfg = m.cfg_from_dict(fx("healthy")["config"])
    v = [x for x in m.evaluate(facts, cfg) if x.name == "landers"][0]
    # 902 cannot be graded, so the population is partial — and 900 is green+unarmed, which is a FAIL.
    assert v.status == m.FAIL or v.variant == "PARTIAL_POPULATION", (v.status, v.variant, v.evidence)


@test
def test_the_REST_probe_bound_is_a_REAL_knob_not_an_internal_constant():
    """`rest_probe_max` bounds how many open PRs the REST fallback probes; a PR beyond it becomes
    `probed: False` and reaches `landers` as PARTIAL_POPULATION. It was read as
    `getattr(cfg, "rest_probe_max", 25)` and declared nowhere, so the bound could not be set from a
    fixture config or a flag — an inert setting, which is the defect class this tool exists to catch.
    """
    m = load()
    assert "rest_probe_max" in m.Cfg.FIELDS
    assert m.Cfg().rest_probe_max == 25
    assert m.Cfg(rest_probe_max=2).rest_probe_max == 2
    assert isinstance(m.Cfg(rest_probe_max="2").rest_probe_max, int)
    assert m.cfg_from_dict({"rest_probe_max": 2}).rest_probe_max == 2
    a = m.build_parser().parse_args(["--static", "--rest-probe-max", "2"])
    assert m.cfg_from_args(a).rest_probe_max == 2

    real, probes = m._run_gh, []

    def fake(argv):
        j = " ".join(argv)
        if "pulls?state=open" in j:
            return 0, json.dumps([{"number": 900 + i, "draft": False, "auto_merge": None,
                                   "mergeable_state": "clean", "head": {"sha": str(i) * 10}}
                                  for i in range(5)])
        if "pulls?state=closed" in j:
            return 0, "[]"
        if "check-runs" in j:
            return 0, json.dumps({"check_runs": [{"conclusion": "success", "name": "ci"}]})
        mm = re.search(r"/pulls/(\d+)$", j)
        if mm:
            probes.append(mm.group(1))
            return 0, json.dumps({"mergeable_state": "clean", "head": {"sha": mm.group(1)[:8]}})
        return 0, "{}"

    try:
        m._run_gh = fake
        gh = m.collect_github("o/r", m.Cfg(rest_probe_max=2), now=1000000.0)
    finally:
        m._run_gh = real
    assert gh["ok"] is True, gh
    assert gh["source"] == "rest", gh.get("source")
    assert len(probes) == 2, probes                     # the bound is honoured, not defaulted
    assert sum(1 for r in gh["open_prs"] if not r["probed"]) == 3, gh["open_prs"]


@test
def test_an_EMPTY_pool_without_a_backlog_field_is_not_graded_idle():
    """One completeness rule, both checks: `queue_readable` calls a header without `backlog=`
    INCONCLUSIVE, so `work_dispatched` must not bless the same line as "genuinely empty"."""
    m = load()
    d = fx("healthy")
    hdr = "=== Sun Oct 18 07:47:44 EST 2026 load=12 lanes=1 queue=EMPTY(12s) ==="
    d["facts"]["log_events"] = {"headers": [{"raw": hdr, "age_s": 60, "ts": 0,
                                             "queue_token": "EMPTY(12s)"}],
                                "dispatch_ok": [], "dispatch_refused": [],
                                "dispatch_empty": [], "dispatch_skipped": [],
                                "armed": [], "railed": []}
    cfg = m.cfg_from_dict(d["config"])
    got = dict((v.name, v) for v in m.evaluate(d["facts"], cfg))
    # the same line must not be graded two ways: no PASS for either check
    assert got["queue_readable"].status != m.PASS, (got["queue_readable"].status,
                                                    got["queue_readable"].variant)
    assert got["work_dispatched"].status == m.INCONCLUSIVE, (
        got["work_dispatched"].status, got["work_dispatched"].variant)
    assert got["work_dispatched"].variant == "HEADER_INCOMPLETE", got["work_dispatched"].variant


@test
def test_a_fixture_expectation_naming_an_unknown_check_is_a_mismatch():
    """An `_expect` key that names no check asserted NOTHING, and the runner still printed "every
    fixture matched" and exited 0 — a no-op gate reporting the opposite of what it did."""
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-badexpect-")
    try:
        d = fx("healthy")
        d["_expect"] = dict((n, "PASS") for n in m.CHECK_ORDER)
        d["_expect"]["lnders"] = "FAIL"            # a NAME that is not a check: asserts nothing
        bad = os.path.join(tmp, "bad.json")
        with open(bad, "w") as fh:
            json.dump(d, fh)
        rc, out, err = run_cli(["--static", "--fixture", bad, "--json"])
        assert rc == 1, (rc, out[-300:])
        j = json.loads(out)
        assert j["mismatches"] and j["mismatches"][0]["got"] == "UNKNOWN_CHECK", j["mismatches"]
        # A KNOWN check excluded by --only is SKIPPED, not a mismatch: the caller asked for a subset.
        # Grading it as one made `--static --only X` fail on every fixture's other expectations (105
        # of them) while the "every fixture matched" branch could never print — an advertised flag
        # pair that could never succeed. It must still be LOUD, or "asserted nothing" goes silent.
        d2 = fx("healthy")
        d2["_expect"] = dict((n, "PASS") for n in m.CHECK_ORDER)
        only = os.path.join(tmp, "only.json")
        with open(only, "w") as fh:
            json.dump(d2, fh)
        rc, out, err = run_cli(["--static", "--fixture", only,
                                "--only", "work_dispatched", "--json"])
        # ⛔ `--only` NARROWS, IT DOES NOT CERTIFY: no mismatch, but 7 of 8 checks were not asserted,
        # so the run must not exit 0. A green exit here is quotable as "the suite passes" while 7/8
        # of it never ran — the same rule the live path enforces with `not_evaluated`.
        assert rc == 2, (rc, out[-300:])
        j = json.loads(out)
        assert j["mismatches"] == [], j["mismatches"]
        assert set(x["check"] for x in j["skipped"]) == set(m.CHECK_ORDER) - {"work_dispatched"}, \
            j["skipped"]
        # …and the whole shipped fixture set can be run against ONE check (it used to fail 105 times)
        rc, out, err = run_cli(["--static", "--fixtures-dir", FIXTURES,
                                "--only", "work_dispatched", "--json"])
        assert rc == 2, (rc, out[-400:])
        j = json.loads(out)
        assert j["mismatches"] == [], j["mismatches"][:3]
        assert len(j["skipped"]) >= 15, len(j["skipped"])
        # a MISMATCH outranks the abstention: an observed FAIL is stronger evidence than "not asked"
        rc, out, err = run_cli(["--static", "--fixture", bad,
                                "--only", "work_dispatched", "--json"])
        assert rc == 1, (rc, out[-300:])
        # and the un-narrowed run still exits 0 on a set that asserts everything
        rc, out, err = run_cli(["--static", "--fixture", only, "--json"])
        assert rc == 0, (rc, out[-300:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_the_GRADED_record_cannot_borrow_the_age_of_the_record_it_beat():
    """`_queue_age` reads both clocks and takes the OLDER, which is right when the two sources describe
    one reading and wrong once `authoritative_queue_token` grades the newer/unaged record: the age of
    the SUPERSEDED header token certified it. Measured: an age-UNKNOWN EMPTY record beside a
    READ(203)(9m) header graded PASS/READABLE + PASS/IDLE_EMPTY_POOL + exit 0, printing "written age
    UNKNOWN" in its own evidence — the documented rule says that is STATE_FROZEN."""
    m = load()
    cfg = m.cfg_from_dict({})
    d = fx("healthy")
    d["facts"]["log_events"]["headers"] = [
        {"raw": "=== Sun Oct 18 07:47:44 EST 2026 load=40 lanes=2 backlog=0 queue=READ(203)(9m) ===",
         "age_s": 42, "ts": 1792327000, "backlog": 0, "queue_token": "READ(203)(9m)", "lanes": 2,
         "load": 40}]
    d["facts"]["log_events"]["dispatch_ok"] = []
    d["facts"]["log_events"]["lane_started"] = []
    d["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "EMPTY", "age_s": None}
    for name in ("queue_readable", "work_dispatched"):
        v = [x for x in m.evaluate(d["facts"], cfg) if x.name == name][0]
        assert (v.status, v.variant) == (m.INCONCLUSIVE, "STATE_FROZEN"), (name, v.status, v.variant)
        assert "state/queue-state" in v.evidence, v.evidence
    # …and the mirror shape (authoritative READ, header EMPTY(9m)) is the same defect, same answer
    d["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "READ(203)", "age_s": 30}
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "queue_readable"][0]
    # a FRESH authoritative READ is graded on its own merits (here the real backlog=0/pool=203 FAIL)
    assert v.status != m.PASS and v.variant == "EMPTY_WITH_LARGE_POOL", (v.status, v.variant)


@test
def test_a_start_REFUTED_by_its_own_failure_line_is_not_a_live_lane():
    """`dispatch-merge.sh:93` prints `#N: chain-N could NOT be started — stopping lane-N` AFTER echoing
    the lane line, and kills it. With the emitter's literal lines for a 3-issue batch (2 worktree
    failures + 1 started-then-killed) the check read PASS/DISPATCHED and printed "3 issue(s)
    dispatched" off the batch INTENT count — the datum the code's own comment forbids grading."""
    m = load()
    cfg = m.cfg_from_dict({})
    log = [
        "=== Sun Oct 18 07:47:44 EST 2026 load=40 lanes=2 backlog=47 queue=READ(223)(9m) ===",
        "[dispatch] load=40 lanes=2 -> 7001 7002 7003",
        "#7001: worktree add failed (branch exists?) \u2014 skipping",
        "#7002: lane-7002 (implement+PR)",
        "#7002: chain-7002 could NOT be started \u2014 stopping lane-7002 (its PR would never be merged)",
        "#7003: worktree add failed (branch exists?) \u2014 skipping",
    ]
    ev = m.parse_log(log, now=1792327664.0)
    v = m.check_work_dispatched({"log_events": ev}, cfg)
    assert (v.status, v.variant) == (m.FAIL, "NO_LANE_STARTED"), (v.status, v.variant, v.evidence)
    # …and when a lane really survives, the PASS counts OUTCOMES and labels the batch line as intent
    ev["lane_failed"] = [e for e in ev["lane_failed"] if e["issue"] != 7002]
    v = m.check_work_dispatched({"log_events": ev}, cfg)
    assert (v.status, v.variant) == (m.PASS, "DISPATCHED"), (v.status, v.variant, v.evidence)
    assert "1 lane(s) STARTED" in v.evidence and "batch INTENT: 3" in v.evidence, v.evidence


@test
def test_a_variant_name_carries_ONE_status_or_the_notifier_silences_the_worse_one():
    """`Verdict.key` is `name|variant` and the notifier suppresses on the key alone, so sharing
    PROTECTION_PARTIAL between "protection could not be proven" (INCONCLUSIVE) and "the daemon is NOT
    protected" (FAIL) delivered the first and silenced the second for good — and only a PASS clears
    the key, which an unprotected daemon never reaches."""
    m = load()
    cfg = m.cfg_from_dict({})
    unread = {"ok": True, "protection_supported": True, "cmd": "cmux-tui",
              "pids": [{"pid": 11, "oom_score_adj": -900}, {"pid": 12, "oom_score_adj": None}]}
    partial = {"ok": True, "protection_supported": True, "cmd": "cmux-tui",
               "pids": [{"pid": 11, "oom_score_adj": -900}, {"pid": 12, "oom_score_adj": 0}]}
    a = m.check_pane_daemon({"pane": unread}, cfg)
    b = m.check_pane_daemon({"pane": partial}, cfg)
    assert (a.status, b.status) == (m.INCONCLUSIVE, m.FAIL), (a.status, b.status)
    assert a.key != b.key, (a.key, b.key)
    # every variant name in the file must map to exactly one status
    import re as _re
    src = open(m.__file__).read()
    pairs = {}
    for name, status, variant in _re.findall(
            r'V\("(\w+)", (PASS|FAIL|INCONCLUSIVE), "(\w+)"', src):
        pairs.setdefault(variant, set()).add(status)
    multi = dict((k, v) for k, v in pairs.items() if len(v) > 1)
    assert not multi, "a variant name carries more than one status: %s" % (multi,)


@test
def test_a_TORN_queue_record_is_a_failed_read_not_a_missing_key():
    """`read_file` returns ("", None) for `cat` of an EMPTY file, and the harness writes the record with
    `>` (truncate, then write), so a full disk — the exact moment `headroom` FAILs — a kill or a reboot
    leaves it EMPTY BUT FRESH. Read as `ok: True, raw: ""` the record was silently dropped, the
    one-refresh-old header decided, and both queue checks answered PASS with a blank printed where the
    verdict should be."""
    m = load()
    cfg = m.cfg_from_dict({"o_dir": "/O"})
    mach = m.Machine(None)
    mach.o_dir = "/O"
    mach.sh = lambda cmd, timeout=None: (0, "")      # cat of an empty file: rc 0, no stdout
    rec = m.read_queue_state(mach, cfg, 1792327664.0)
    assert rec["ok"] is False, rec
    assert "torn" in (rec.get("error") or ""), rec
    # a readable record still parses, with its epoch
    mach.sh = lambda cmd, timeout=None: (0, "READ(203) 1792327600")
    rec = m.read_queue_state(mach, cfg, 1792327664.0)
    assert rec["ok"] is True and rec["raw"] == "READ(203) 1792327600", rec
    assert rec["age_s"] == 64.0, rec
    # a record whose epoch was never written still gets its age from the FILE, not from nothing
    mach.sh = lambda cmd, timeout=None: (0, "READ(203)")
    mach.stat_mtime = lambda path: 1792327600
    rec = m.read_queue_state(mach, cfg, 1792327664.0)
    assert rec["age_s"] == 64.0 and rec["age_source"] == "file mtime", rec


@test
def test_the_queue_checks_use_ALLOW_LIST_polarity_on_the_record():
    """`is False` / `is not False` at the two queue sites let an ABSENT `queue_state` key grade
    PASS/READABLE over nothing that was read — the one rule the file states for every other collector."""
    m = load()
    cfg = m.cfg_from_dict({})
    d = fx("healthy")
    del d["facts"]["queue_state"]
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "queue_readable"][0]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "QUEUE_STATE_UNREADABLE"), (v.status, v.variant)
    # a blind box is not an idle one: with no dispatch line and an EMPTY header token the IDLE branch
    # is the one that would fire, and it must stay shut without a READ record
    d["facts"]["log_events"]["dispatch_ok"] = []
    d["facts"]["log_events"]["lane_started"] = []
    d["facts"]["log_events"]["headers"] = [
        {"raw": "=== Sun Oct 18 07:47:44 EST 2026 load=5 lanes=0 backlog=0 queue=EMPTY(3m) ===",
         "age_s": 180, "ts": 1792327000, "backlog": 0, "queue_token": "EMPTY(3m)", "lanes": 0,
         "load": 5}]
    w = [x for x in m.evaluate(d["facts"], cfg) if x.name == "work_dispatched"][0]
    assert w.variant != "IDLE_EMPTY_POOL" and w.status != m.PASS, (w.status, w.variant)


@test
def test_an_ok_MEMORY_read_with_no_number_is_UNREAD_not_zero_mib():
    """The disk arm's twin: `(avail_mb or 0)` manufactured "0 MiB available" from a field that was never
    read, i.e. an OOM emergency on the check whose FAIL must mean one."""
    m = load()
    cfg = m.cfg_from_dict({})
    hr = {"disk": {"ok": True, "avail_bytes": int(400 * (1 << 30)), "used_pct": 40.0, "mount": "/"},
          "mem": {"ok": True, "source": "linux"}}
    v = m.check_headroom({"headroom": hr}, cfg)
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "PROBE_UNREADABLE"), (v.status, v.variant)
    assert "avail_mb" in v.evidence, v.evidence


@test
def test_the_vm_stat_awk_refuses_a_NUMBER_when_any_SUMMED_field_is_missing():
    """`inact` and `spec` are summed but were never checked, so a reworded label silently contributed
    0 — measured on this box, rewording two page-count labels turned 7.0 GiB into 214 MiB and produced
    FAIL/BELOW_FLOOR on a healthy machine."""
    m = load()
    mach = m.Machine(None)
    seen = {}

    def fake_sh(cmd, timeout=None):
        if "df -k" in cmd:
            return (0, "/dev/disk1 100 900000000 400000000 40% /")
        seen["mem_cmd"] = cmd
        return (0, "darwin UNKNOWN")

    mach.sh = fake_sh
    hr = mach.headroom("/")
    for field in ("ps", "free", "inact", "spec"):
        assert '|| %s == ""' % field in seen["mem_cmd"], (field, seen["mem_cmd"])
    assert hr["mem"]["ok"] is False, hr["mem"]


@test
def test_the_merged_page_bound_models_the_SURFACE_that_produced_it():
    """A 100-row page is not a truncated POPULATION unless the page's ORDERING can hide a row.

    `gh pr list` is CREATION-desc, so `--limit 100` bounds CREATION and a PR created 8+ days ago and
    merged in the last 3h sits outside the page — real truncation. REST is
    `sort=updated&direction=desc`, so a 100-row page whose oldest `updated_at` is 38.65h old covers a
    3h window COMPLETELY (measured on the live target). Keying the flag on `len(closed) >= 100`
    alone made every full closed page "truncated", which deleted `pr_merged`'s only FAIL arm on the
    shipped repo: a genuinely quiet fleet could never be reported as such."""
    m = load()
    cfg = m.cfg_from_dict({"pr_window_s": 10800.0})
    now = 1792327664.0
    closed = [{"number": i, "merged_at": None, "created_at": "2026-10-01T00:00:00Z"} for i in range(100)]
    merged = [{"number": i, "merged_at": "2026-10-18T10:00:00Z"} for i in range(97)]
    # the collector decides; `_fill_counts` only stores the verdict input
    out = {}
    m._fill_counts(out, closed, merged, cfg, now, also_created=closed, merged_page_full=True)
    assert out["merged_page_full"] is True, out
    m._fill_counts(out, closed[:10], merged[:10], cfg, now, also_created=closed[:10],
                   merged_page_full=False)
    assert out["merged_page_full"] is False, out
    # …and a caller that cannot say abstains: unprovable coverage is TRUNCATED, never "complete"
    m._fill_counts(out, closed, merged, cfg, now)
    assert out["merged_page_full"] is True, out


@test
def test_the_REST_collector_does_NOT_call_a_covering_page_TRUNCATED():
    """The wiring of the fix above: `_collect_rest` must compute the bound from `updated_at` vs the
    window, not from the row count — and must pass the closed page as `also_created` (a PR opened and
    then closed unmerged was still opened)."""
    m = load()
    cfg = m.cfg_from_dict({"pr_window_s": 10800.0})
    now = 1792327664.0
    closed = [{"number": i, "merged_at": None, "created_at": "2026-10-01T00:00:00Z"}
              for i in range(100)]
    page = [{"number": p["number"], "merged_at": p["merged_at"], "draft": False,
             "auto_merge": None, "updated_at": "2026-10-16T00:00:00Z",     # 38h+ old: covers 3h
             "state": "closed", "created_at": "2026-10-01T00:00:00Z"} for p in closed]
    inside = "2026-10-18T19:40:00Z"          # 64s before `now`
    page[0] = dict(page[0], merged_at=inside, updated_at=inside, created_at=inside)
    page[1] = dict(page[1], created_at=inside)                          # opened, closed unmerged

    calls = []
    real = m._run_gh

    def fake(argv):
        calls.append(" ".join(argv))
        j = " ".join(argv)
        if "pulls?state=open" in j:
            return 0, "[]"
        if "pulls?state=closed" in j:
            return 0, json.dumps(page)
        return 0, ""

    try:
        m._run_gh = fake
        gh = m.collect_github("o/r", cfg, now=now)
    finally:
        m._run_gh = real
    assert gh and gh.get("ok") is True, gh
    assert gh["source"] == "rest", gh
    # a page that reaches past the window is NOT truncated, so pr_merged keeps its FAIL arm
    assert gh["merged_page_full"] is False, gh
    # …and a PR opened and closed unmerged is still a PR the fleet OPENED
    assert gh["prs_created_in_window"] == 2, gh["prs_created_in_window"]
    assert any("sort=updated" in c for c in calls), calls


@test
def test_the_GRAPHQL_collector_reads_the_CLOSED_page_AND_a_MERGE_ordered_page():
    """Two populations, two orderings. The CLOSED page (creation-desc) answers "what was opened" —
    without it a PR opened and closed unmerged vanished from the created count. It CANNOT answer
    "did anything merge in the window": on any repo with >=100 closed PRs the page is always full and
    a merge older than the page cut is invisible, which made `merged_page_full` true on every live
    run and deleted `pr_merged`'s only FAIL arm (measured: 100 closed rows on this repo). So one
    MERGE-ORDERED read (`merged:>=<date>`) carries the merge count, and an EMPTY result of it
    genuinely establishes "nothing merged in the window"."""
    m = load()
    cfg = m.cfg_from_dict({"pr_window_s": 10800.0})
    # ⛔ `now` IS CHOSEN SO A WINDOW-SIZED SHIFT CHANGES THE DATE. With a mid-afternoon `now` the
    # `±3h` bound floors to the SAME day, so a mutant that moves it a window into the future — which
    # on the real surface excludes every in-window merge, i.e. a false NO_PR_MERGED — is
    # indistinguishable from the correct code. 01:00Z sits 3h from the previous date boundary.
    now = m.datetime.datetime(2026, 10, 18, 1, 0, tzinfo=m.datetime.timezone.utc).timestamp()
    inside = m._iso(now - 600)
    closed = [{"number": i, "createdAt": inside, "mergedAt": None} for i in range(100)]
    closed[0] = dict(closed[0], mergedAt=inside)
    calls, merge_rows = [], {"rows": []}
    real = m._run_gh

    def fake(argv):
        j = " ".join(argv)
        calls.append(j)
        if "--state open" in j:
            return 0, "[]"
        if "--state closed" in j:
            return 0, json.dumps(closed)
        if "merged:>=" in j:
            merge_rows["bound"] = j.split("merged:>=")[1].split()[0].strip('"')
            return 0, json.dumps(merge_rows["rows"])
        return 0, ""

    try:
        m._run_gh = fake
        # (a) nothing merged in the window: the merge-ordered page is EMPTY, which is a measurement,
        #     so the truncation flag must NOT fire and the FAIL arm stays reachable
        gh = m.collect_github("o/r", cfg, now=now)
        assert gh and gh.get("source") == "graphql", gh
        assert gh["merged_page_full"] is False, gh
        assert gh["prs_merged_in_window"] == 0, gh
        # …and the closed page still supplies the created population
        assert gh["prs_created_in_window"] == 100, gh
        check = m.check_pr_merged({"github": dict(gh, open_pr_count=2)}, cfg)
        assert (check.status, check.variant) == (m.FAIL, "NO_PR_MERGED"), (check.status,
                                                                          check.variant)
        # (b) a merge inside the window is counted, and the search is bounded by the window's date
        merge_rows["rows"] = [{"number": 1, "mergedAt": inside, "createdAt": inside}]
        gh2 = m.collect_github("o/r", cfg, now=now)
        assert gh2["prs_merged_in_window"] == 1, gh2
        assert "merged:>=" in gh2.get("merged_surface", ""), gh2
        # ⛔ and the merge-ordered read is DATED, AND THE DATE IS THE ONE THAT MATTERS. Asserting only
        # that a `merged:>=` appears let a mutant move the bound a whole window into the FUTURE (which
        # excludes every in-window merge on the real surface, i.e. a false NO_PR_MERGED) pass the
        # entire suite. A day-floored bound can only move EARLIER and `_fill_counts` re-filters with
        # the exact window, so the query must be a SUPERSET of the window: `bound <= window start`.
        assert any("--search" in c and "merged:>=" in c for c in calls), calls
        want = m.datetime.datetime.fromtimestamp(
            now - 10800.0, m.datetime.timezone.utc).strftime("%Y-%m-%d")
        assert merge_rows.get("bound") == want, (merge_rows.get("bound"), want)
    finally:
        m._run_gh = real

    # (c) the merge-ordered read FAILS: fall back to the creation-ordered page and DISCLOSE the bound
    def fake_fail(argv):
        j = " ".join(argv)
        if "--state open" in j:
            return 0, "[]"
        if "--state closed" in j:
            return 0, json.dumps(closed)
        if "merged:>=" in j:
            return 1, "GraphQL: something went wrong"
        return 0, ""

    try:
        m._run_gh = fake_fail
        gh3 = m.collect_github("o/r", cfg, now=now)
    finally:
        m._run_gh = real
    assert gh3["merged_page_full"] is True, gh3       # abstain rather than under-count silently
    assert "merge-ordered read failed" in (gh3.get("fallback_note") or ""), gh3


@test
def test_an_EMPTY_backlog_is_judged_against_the_pool_from_ITS_OWN_header():
    """`backlog=` and `queue=` are written on ONE header line by ONE cycle; the graded token can come
    from a NEWER `state/queue-state`, which carries no backlog. Pairing its pool with the header's
    backlog compares two refreshes and reports the difference as a defect (#1931's shape, falsely)."""
    m = load()
    cfg = m.cfg_from_dict({"pool_threshold": 25})
    facts = {"log_events": {"headers": [{"raw": "=== h load=3 lanes=0 backlog=0 queue=READ(10) ===",
                                         "age_s": 40, "ts": 0, "backlog": 0,
                                         "queue_token": "READ(10)"}]},
             "queue_state": {"path": "q", "ok": True, "raw": "READ(223) 1792327000", "age_s": 20.0}}
    got = [v for v in m.evaluate(facts, cfg) if v.name == "queue_readable"][0]
    # the header's own pair (backlog=0, pool=10) is not the #1931 shape
    assert got.status == m.PASS, (got.status, got.variant, got.evidence)
    assert "READ(223)" in got.evidence, got.evidence       # …and the disagreement is PRINTED
    # the header's own pair IS the shape when its pool is large
    facts["log_events"]["headers"][0].update({"queue_token": "READ(223)",
                                             "raw": "=== h load=3 lanes=0 backlog=0 queue=READ(223) ==="})
    got2 = [v for v in m.evaluate(facts, cfg) if v.name == "queue_readable"][0]
    assert (got2.status, got2.variant) == (m.FAIL, "EMPTY_WITH_LARGE_POOL"), (got2.status,
                                                                             got2.variant)


@test
def test_an_EMPTY_state_record_supersedes_an_older_header_backlog():
    """`backlog=` is written by ONE cycle header from the PREVIOUS refresh's `candidates.txt`, so it
    cannot be attributed to a NEWER `state/queue-state`. Measured: header `backlog=47` beside a
    20s-old `state/queue-state: EMPTY` produced "backlog=47 pool=None (source: state/queue-state)"
    and two FAILs ("the fleet HAD WORK IN HAND") about a superseded refresh."""
    m = load()
    cfg = m.cfg_from_dict({})
    facts = {"github": {"open_pr_count": 0, "open_prs": []},
             "log_events": {"headers": [{"raw": "h", "age_s": 60, "backlog": 47,
                                        "queue_token": "READ(200)"}]},
             "queue_state": {"path": "q", "ok": True, "raw": "EMPTY 1792327000", "age_s": 20.0}}
    busy, why = m._activity(facts, cfg.window_s)
    assert busy is False, (busy, why)
    assert "supersedes" in why and "state/queue-state" in why, why
    # …and when the header is the graded record its backlog is named as the header's own
    facts2 = {"github": {"open_pr_count": 0, "open_prs": []},
              "log_events": {"headers": [{"raw": "h", "age_s": 60, "backlog": 47,
                                         "queue_token": "READ(200)"}]},
              "queue_state": {"path": "q", "ok": True, "raw": "READ(200)", "age_s": 900.0}}
    busy2, why2 = m._activity(facts2, cfg.window_s)
    assert busy2 is True, (busy2, why2)
    assert "source: cycle header" in why2, why2


@test
def test_pr_merged_abstains_when_the_activity_input_is_unread():
    """The two PR checks answer one question, so they must answer it the same way: `pr_created`
    abstained ACTIVITY_UNKNOWN on the #1931 blind-pool shape while `pr_merged` FAILed NO_PR_MERGED
    off the very same facts — a FAIL block whose own evidence disclaimed the reading it used."""
    m = load()
    cfg = m.cfg_from_dict({})
    gh = {"ok": True, "prs_merged_in_window": 0, "open_pr_count": 1, "open_prs": [],
          "source": "rest", "merged_page_full": False, "prs_created_in_window": 0}
    facts = {"github": dict(gh, open_pr_count=0),
             "log_events": {"headers": [{"raw": "h", "age_s": 60, "backlog": 0,
                                         "queue_token": "UNREADABLE"}]},
             "queue_state": {"path": "q", "ok": False, "error": "permission denied"}}
    got = dict((v.name, v) for v in m.evaluate(facts, cfg))
    assert got["pr_merged"].variant == "ACTIVITY_UNKNOWN", (got["pr_merged"].status,
                                                             got["pr_merged"].variant)
    assert got["pr_created"].variant == "ACTIVITY_UNKNOWN", got["pr_created"].variant
    # …and a KNOWN activity still FAILs with open PRs and nothing merged
    facts2 = {"github": gh,
              "log_events": {"headers": [{"raw": "h", "age_s": 60, "backlog": 5,
                                          "queue_token": "READ(200)"}]},
              "queue_state": {"path": "q", "ok": True, "raw": "READ(200)", "age_s": 60.0}}
    got2 = dict((v.name, v) for v in m.evaluate(facts2, cfg))
    assert got2["pr_merged"].variant == "NO_PR_MERGED", (got2["pr_merged"].status,
                                                         got2["pr_merged"].variant)


@test
def test_a_FAILED_TAIL_is_a_MISSING_read_not_an_empty_log():
    """`read_log` discarded the `tail` exit status, so a log whose CONTENT could not be read (EACCES,
    TCC, a timed-out remote exec) returned an empty line list with a fresh mtime — and
    `controller_cycling` graded the pair FAIL/LOG_NO_CYCLE ("the log IS advancing, but not by a
    cycle"): a measured claim about content that was never read, on the check an operator reads
    first. `queue_readable` abstains on the same datum."""
    m = load()
    cfg = m.cfg_from_dict({})
    # ── the COLLECTOR contract: a failed tail must come back as a failed read ────────────────────
    mach = m.Machine()
    calls = []

    def fake_sh(cmd, timeout=None):
        calls.append(cmd)
        if cmd.startswith("stat"):
            return 0, "1792327000\n"
        if cmd.startswith("tail"):
            return 1, "tail: Permission denied"
        return 0, ""

    mach.sh = fake_sh
    rec, lines, err = mach.read_log("/o/orch-loop.log")
    assert rec["exists"] is True and rec["tail_ok"] is False, rec
    assert lines == [] and "Permission denied" in (rec.get("tail_error") or ""), rec
    assert err is None, err
    # ── the PREDICATE: a fresh mtime with unreadable contents abstains, never LOG_NO_CYCLE ──────
    facts = {"controller": {"ok": True, "pids": [{"pid": 4242, "cmd": "/bin/zsh /o/orch-loop.sh"}],
                            "launchd": {"loaded": True, "pid": 4242}},
             "log": rec,
             "heartbeat": {"ok": True, "age_s": 15.0},
             "pane": {"ok": True, "pids": [], "protection_supported": False},
             "headroom": {"disk": {"ok": True, "avail_bytes": int(400 * (1 << 30)), "used_pct": 10,
                                   "mount": "/"}, "mem": {"ok": True, "avail_mb": 9000, "source": "d"}},
             "github": {"ok": True, "open_pr_count": 0, "open_prs": [], "source": "rest",
                        "prs_created_in_window": 1, "prs_merged_in_window": 1},
             "log_events": {"headers": [], "dispatch_ok": [], "lane_started": [], "lane_failed": [],
                            "armed": [], "railed": []}}
    v = [x for x in m.evaluate(facts, cfg) if x.name == "controller_cycling"][0]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "LOG_UNREADABLE"), (v.status, v.variant)
    assert "Permission denied" in v.evidence, v.evidence
    # …and a READABLE, empty tail is still the wedge it says it is
    facts["log"] = dict(rec, tail_ok=True, tail_error=None)
    v2 = [x for x in m.evaluate(facts, cfg) if x.name == "controller_cycling"][0]
    # a readable log with no cycle header in it is the wedge it says it is (LOG_NO_CYCLE) — or, with
    # no headers at all and a fresh heartbeat, LOG_SILENT
    assert v2.status == m.FAIL and v2.variant in ("LOG_NO_CYCLE", "LOG_SILENT"), (v2.status,
                                                                                 v2.variant)


@test
def test_a_STALE_read_cannot_grade_work_as_NOT_dispatched():
    """`work_dispatched` exempted a stale NON-EMPTY read with a non-empty backlog from its staleness
    abstention, so it graded FAIL/NO_DISPATCH ("the refresh reported 47 candidate(s) and no dispatch
    line was written") off a reading six hours old — while `queue_readable`, on the SAME facts dict,
    abstained READABLE_STALE. Two checks, one record, opposite answers, and the FAIL was the one that
    would page someone about a box whose refresh had merely frozen."""
    m = load()
    d = fx("healthy")
    d["facts"]["log_events"]["headers"] = [{
        "raw": "=== Sun Oct 18 07:47:44 EST 2026 load=12 lanes=1 backlog=47 queue=READ(223)(6h) ===",
        "age_s": 60, "ts": 0, "backlog": 47, "queue_token": "READ(223)(6h)"}]
    d["facts"]["log_events"]["dispatch_ok"] = []
    d["facts"]["log_events"]["lane_started"] = []
    d["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "READ(223)", "age_s": 6 * 3600.0}
    cfg = m.cfg_from_dict(d["config"])
    got = dict((v.name, v) for v in m.evaluate(d["facts"], cfg))
    assert got["work_dispatched"].status == m.INCONCLUSIVE, got["work_dispatched"].as_json()
    assert got["work_dispatched"].variant == "STATE_FROZEN", got["work_dispatched"].variant
    assert got["queue_readable"].variant == "READABLE_STALE", got["queue_readable"].variant
    # both checks answer "that record is not current" — never one FAIL beside one abstention
    assert got["work_dispatched"].status == got["queue_readable"].status, (
        got["work_dispatched"].as_json(), got["queue_readable"].as_json())
    # …and a CURRENT read of the same shape is still the FAIL: work existed and did not move
    d["facts"]["log_events"]["headers"][0].update({"queue_token": "READ(223)", "raw": "=== h ===",
                                                   "age_s": 30})
    d["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "READ(223)", "age_s": 30.0}
    cfg2 = m.cfg_from_dict(d["config"])
    got2 = dict((v.name, v) for v in m.evaluate(d["facts"], cfg2))
    assert (got2["work_dispatched"].status, got2["work_dispatched"].variant) == (
        m.FAIL, "NO_DISPATCH"), (got2["work_dispatched"].status, got2["work_dispatched"].variant)


@test
def test_a_current_EMPTY_state_record_supersedes_the_headers_large_pool():
    """The header's `queue=` and `backlog=` are ONE refresh old; a newer `state/queue-state: EMPTY`
    supersedes both. Grading the header's pair anyway produced `queue_readable`
    FAIL/EMPTY_WITH_LARGE_POOL beside `work_dispatched` PASS/IDLE_EMPTY_POOL for ONE facts dict, with
    the FAIL's own evidence saying "graded from: state/queue-state (it is NEWER than the header)"."""
    m = load()
    cfg = m.cfg_from_dict({"pool_threshold": 25})
    facts = {"github": {"ok": True, "open_pr_count": 0, "open_prs": [], "source": "rest",
                        "prs_created_in_window": 1, "prs_merged_in_window": 1},
             "log_events": {"headers": [{"raw": "=== h load=3 lanes=0 backlog=0 queue=READ(198)(3m) ===",
                                         "age_s": 42, "ts": 0, "backlog": 0,
                                         "queue_token": "READ(198)(3m)"}],
                            "dispatch_ok": [], "lane_started": [], "lane_failed": [],
                            "armed": [], "railed": []},
             "queue_state": {"path": "q", "ok": True, "raw": "EMPTY 1792327000", "age_s": 40.0}}
    got = dict((v.name, v) for v in m.evaluate(facts, cfg))
    assert got["queue_readable"].status == m.PASS, (got["queue_readable"].status,
                                                    got["queue_readable"].variant,
                                                    got["queue_readable"].evidence)
    assert got["work_dispatched"].variant == "IDLE_EMPTY_POOL", got["work_dispatched"].variant
    # …and the header's own pair IS graded when no newer record supersedes it
    facts["queue_state"] = {"path": "q", "ok": True, "raw": "READ(198) 1792327000", "age_s": 900.0}
    got2 = dict((v.name, v) for v in m.evaluate(facts, cfg))
    assert got2["queue_readable"].variant == "EMPTY_WITH_LARGE_POOL", (got2["queue_readable"].status,
                                                                      got2["queue_readable"].variant)


@test
def test_a_LEGIBLE_BUT_OLD_non_empty_read_is_not_GREEN():
    """A KNOWN-and-old NON-EMPTY read graded PASS/READABLE, so a box whose refresh froze three hours
    ago exited 0 for the WHOLE run while the controller dispatched off a stale `candidates.txt` — the
    #1931 failure wearing a pass."""
    m = load()
    cfg = m.cfg_from_dict({"queue_stale_s": 5400.0})
    now = 1792327664.0
    facts = {"github": {"ok": True, "open_pr_count": 0, "open_prs": [], "source": "rest",
                        "prs_created_in_window": 1, "prs_merged_in_window": 1},
             "log_events": {"headers": [{"raw": "=== h load=3 lanes=0 backlog=47 queue=READ(223)(3h) ===",
                                         "age_s": 60, "ts": 0, "backlog": 47,
                                         "queue_token": "READ(223)(3h)"}],
                            "dispatch_ok": [], "lane_started": [], "lane_failed": [],
                            "armed": [], "railed": []},
             "queue_state": {"path": "q", "ok": True, "raw": "READ(223) %d" % int(now - 10800),
                             "age_s": 10800.0}}
    v = [x for x in m.evaluate(facts, cfg) if x.name == "queue_readable"][0]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "READABLE_STALE"), (v.status, v.variant,
                                                                         v.evidence)
    assert "3.0h" in v.evidence, v.evidence
    # a FRESH non-empty read is still a plain PASS
    facts["log_events"]["headers"][0].update({"queue_token": "READ(223)", "raw": "=== h queue=READ(223) ===",
                                              "age_s": 30})
    facts["queue_state"] = {"path": "q", "ok": True, "raw": "READ(223) %d" % int(now - 30), "age_s": 30.0}
    v2 = [x for x in m.evaluate(facts, cfg) if x.name == "queue_readable"][0]
    assert (v2.status, v2.variant) == (m.PASS, "READABLE"), (v2.status, v2.variant)


@test
def test_a_FULL_merge_ordered_page_is_disclosed():
    """`merged:>=<day-floored date>` is bounded by the DAY, not by `pr_window_s`, so a full page can
    hold zero in-window rows and hide the merge that matters. Hardcoding `merged_page_full=False`
    there asserted "nothing merged" off a cut page."""
    m = load()
    cfg = m.cfg_from_dict({"pr_window_s": 10800.0})
    now = 1792327664.0
    inside = m._iso(now - 600)
    outside = m._iso(now - 20000)
    rows = [{"number": i, "createdAt": outside, "mergedAt": outside} for i in range(100)]
    real = m._run_gh

    def fake(argv):
        j = " ".join(argv)
        if "--state open" in j:
            return 0, "[]"
        if "--state closed" in j:
            return 0, json.dumps([{"number": 1, "createdAt": inside, "mergedAt": None}])
        if "merged:>=" in j:
            return 0, json.dumps(rows)
        return 0, ""

    try:
        m._run_gh = fake
        gh = m.collect_github("o/r", cfg, now=now)
    finally:
        m._run_gh = real
    assert gh["prs_merged_in_window"] == 0, gh
    assert gh["merged_page_full"] is True, gh       # a FULL page is a bound, whatever its ordering
    v = m.check_pr_merged({"github": gh}, cfg)
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "MERGED_SURFACE_TRUNCATED"), (v.status, v.variant)


@test
def test_the_report_says_WHICH_READ_produced_the_merge_count():
    """`merged_surface`/`fallback_note` were written by the collector and read by NOTHING, so a
    report could not tell a window-bounded merge count from a creation-ordered-page count — and the
    `no-pr-merged` fixture's own stated reason ("the merge-ordered read succeeded and returned
    nothing") was asserted by no test."""
    m = load()
    cfg = m.cfg_from_dict({"pr_window_s": 10800.0})
    gh = {"ok": True, "prs_merged_in_window": 0, "open_pr_count": 1, "open_prs": [], "source": "graphql",
          "merged_page_full": False, "merged_surface": "merge-ordered (merged:>=2026-10-18)"}
    v = m.check_pr_merged({"github": gh}, cfg)
    assert "merge-ordered (merged:>=2026-10-18)" in v.evidence, v.evidence
    # the fallback shape discloses the bound it fell back to
    gh2 = dict(gh, merged_surface=None,
               fallback_note="merge-ordered read failed (rc=1); merged count is from the "
                             "creation-ordered closed page")
    v2 = m.check_pr_merged({"github": gh2}, cfg)
    assert "creation-ordered closed page" in v2.evidence, v2.evidence
    # …and the shipped fixture carries exactly the shape it claims
    d = fx("no-pr-merged")
    assert d["facts"]["github"]["merged_surface"].startswith("merge-ordered"), d["facts"]["github"]
    got = [x for x in m.evaluate(d["facts"], m.cfg_from_dict(d["config"])) if x.name == "pr_merged"][0]
    assert got.variant == "NO_PR_MERGED", (got.status, got.variant)
    assert "merge-ordered" in got.evidence, got.evidence


@test
def test_an_UNPARSEABLE_header_is_NOT_a_mid_cycle_wedge():
    """`parse_log` counts a header it cannot parse in `unparsed_headers`; `queue_readable` and
    `work_dispatched` both abstain on it, and `controller_cycling` graded the same datum
    FAIL/LOG_NO_CYCLE ("a mid-cycle wedge") — a MEASURED failure from a value it could not read, on
    the check an operator reads first, for a controller whose log format had merely moved."""
    m = load()
    d = fx("healthy")
    d["facts"]["log_events"]["headers"] = []
    d["facts"]["log_events"]["unparsed_headers"] = 5
    cfg = m.cfg_from_dict(d["config"])
    got = dict((v.name, v) for v in m.evaluate(d["facts"], cfg))
    v = got["controller_cycling"]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "LOG_FORMAT_UNREAD"), (v.status, v.variant)
    assert "UNPARSEABLE" in v.evidence, v.evidence
    assert got["queue_readable"].status == m.INCONCLUSIVE, got["queue_readable"].status
    # …and with NO unparseable headers, zero cycles is still the wedge it says it is
    d2 = fx("healthy")
    d2["facts"]["log_events"]["headers"] = []
    cfg2 = m.cfg_from_dict(d2["config"])
    v2 = [x for x in m.evaluate(d2["facts"], cfg2) if x.name == "controller_cycling"][0]
    assert (v2.status, v2.variant) == (m.FAIL, "LOG_NO_CYCLE"), (v2.status, v2.variant)


@test
def test_a_BOOL_headroom_number_is_UNREAD_not_a_manufactured_OOM():
    """`isinstance(True, int)` is true, so a boolean `avail_bytes`/`avail_mb` was divided and
    subtracted as a number: "disk: 0.0 GiB free", "memory: 1 MiB available" — a fake OOM emergency
    manufactured on the check whose FAIL must mean one."""
    m = load()
    cfg = m.cfg_from_dict({})
    v = m.check_headroom({"headroom": {"disk": {"ok": True, "avail_bytes": True, "used_pct": 10,
                                                "mount": "/"},
                                       "mem": {"ok": True, "avail_mb": 9000, "source": "d"}}}, cfg)
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "PROBE_UNREADABLE"), (v.status, v.variant)
    v2 = m.check_headroom({"headroom": {"disk": {"ok": True, "avail_bytes": int(400 * (1 << 30)),
                                                 "used_pct": 10, "mount": "/"},
                                        "mem": {"ok": True, "avail_mb": True, "source": "d"}}}, cfg)
    assert (v2.status, v2.variant) == (m.INCONCLUSIVE, "PROBE_UNREADABLE"), (v2.status, v2.variant)


@test
def test_an_UNREADABLE_pool_is_not_reported_as_benign_idleness():
    """"The fleet had nothing in hand" is a CLAIM, and an `UNREADABLE` pool cannot support it. Every
    non-numeric kind fell through to `busy=False`, so the #1931 shape (blind fleet) was reported as
    idleness by `pr_created` while `queue_readable` FAILed QUEUE_UNREADABLE in the same run."""
    m = load()
    d = fx("healthy")
    d["facts"]["log_events"]["headers"] = [{"raw": "=== Sun Oct 18 07:47:44 EST 2026 load=4 lanes=0 "
                                                   "backlog=0 queue=UNREADABLE ===",
                                            "age_s": 60, "ts": 0, "backlog": 0,
                                            "queue_token": "UNREADABLE"}]
    d["facts"]["queue_state"] = {"path": "q", "ok": False, "error": "permission denied"}
    d["facts"]["github"]["prs_created_in_window"] = 0
    d["facts"]["github"]["prs_merged_in_window"] = 0
    d["facts"]["github"]["open_pr_count"] = 0
    d["facts"]["github"]["open_prs"] = []
    d["facts"]["log_events"]["dispatch_ok"] = []
    d["facts"]["log_events"]["lane_started"] = []
    cfg = m.cfg_from_dict(d["config"])
    got = dict((v.name, v) for v in m.evaluate(d["facts"], cfg))
    assert got["pr_created"].variant == "ACTIVITY_UNKNOWN", (got["pr_created"].status,
                                                             got["pr_created"].variant)
    assert got["pr_merged"].variant in ("ACTIVITY_UNKNOWN", "NO_PR_MERGED"), got["pr_merged"].variant
    busy, why = m._activity(d["facts"], cfg.window_s)
    assert busy is None and "not established" in why, (busy, why)
    # a genuinely EMPTY pool is still a measured idle, not an abstention
    d2 = fx("healthy")
    d2["facts"]["github"]["prs_created_in_window"] = 0
    busy2, _ = m._activity(d2["facts"], m.cfg_from_dict(d2["config"]).window_s)
    assert busy2 is not None, busy2


@test
def test_the_report_discloses_WHICH_CELL_was_read():
    """`--o` is how a cell is named, and two runs against different cells emitted identical config
    blocks: `o_dir`/`log_path`/`state_path` are `None` in DEFAULTS, so a
    `isinstance(v, (int, float, str))` loop over DEFAULTS could never require them."""
    m = load()
    a = m.cfg_from_dict({})
    a.o_dir, a.log_path, a.state_path = "/cell/A", "/cell/A/logs/orch-loop.log", "/cell/A/q"
    b = m.cfg_from_dict({})
    b.o_dir, b.log_path, b.state_path = "/cell/B", "/cell/B/logs/orch-loop.log", "/cell/B/q"
    assert a.as_json() != b.as_json(), (a.as_json(), b.as_json())
    assert a.as_json()["o_dir"] == "/cell/A", a.as_json()
    # every Cfg.FIELDS member is disclosed, so a report can explain which records it read
    missing = [k for k in m.Cfg.FIELDS if k not in a.as_json()]
    assert not missing, "undisclosed config fields: %s" % (missing,)


@test
def test_an_ABSENT_pane_population_is_not_a_measured_ZERO_daemons():
    """`pids or []` sent an unread population into `FAIL/DAEMON_ABSENT` — "processes matching
    cmux-tui: 0", a MEASURED failure from a value never read. `check_landers` already rejects an
    absent `open_prs` list the same way."""
    m = load()
    cfg = m.cfg_from_dict({})
    v = m.check_pane_daemon({"pane": {"ok": True, "cmd": "cmux-tui", "protection_supported": True,
                                      "protection_source": "oom_score_adj"}}, cfg)
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "PROCESS_TABLE_UNREADABLE"), (v.status, v.variant)
    assert "pids" in v.evidence, v.evidence
    # an EMPTY list is a real read of "no daemon" and still FAILs
    v2 = m.check_pane_daemon({"pane": {"ok": True, "pids": [], "cmd": "cmux-tui"}}, cfg)
    assert (v2.status, v2.variant) == (m.FAIL, "DAEMON_ABSENT"), (v2.status, v2.variant)


@test
def test_a_STALE_header_cannot_manufacture_work_in_hand():
    """`_activity` read the newest header with NO freshness bound, so a three-day-old
    `backlog=47 pool=223` turned an idle fleet into FAIL/NO_PR_CREATED + FAIL/NO_PR_MERGED ("the
    fleet HAD WORK IN HAND") while `queue_readable`/`work_dispatched` abstained on the same facts."""
    m = load()
    d = fx("healthy")
    for name in ("headers", "dispatch_ok", "lane_started", "lane_failed", "armed", "railed",
                 "dispatch_refused", "dispatch_empty", "dispatch_skipped"):
        for e in d["facts"]["log_events"].get(name) or []:
            e["age_s"] = 300000.0
    d["facts"]["github"]["prs_created_in_window"] = 0
    d["facts"]["github"]["prs_merged_in_window"] = 0
    d["facts"]["github"]["open_pr_count"] = 0
    d["facts"]["github"]["open_prs"] = []
    cfg = m.cfg_from_dict(d["config"])
    got = dict((v.name, v) for v in m.evaluate(d["facts"], cfg))
    assert got["pr_created"].variant == "IDLE_NO_WORK", (got["pr_created"].status,
                                                         got["pr_created"].variant)
    assert got["pr_merged"].variant == "IDLE_NO_WORK", (got["pr_merged"].status,
                                                        got["pr_merged"].variant)
    busy, why = m._activity(d["facts"], cfg.window_s)
    assert busy is False and "inside the window" in why, (busy, why)
    # …a FRESH header with a backlog still says busy, with the age of the header that carried it
    d2 = fx("healthy")
    d2["facts"]["github"]["open_pr_count"] = 0
    d2["facts"]["github"]["open_prs"] = []
    d2["facts"]["log_events"]["dispatch_ok"] = []
    d2["facts"]["log_events"]["lane_started"] = []
    busy2, why2 = m._activity(d2["facts"], m.cfg_from_dict(d2["config"]).window_s)
    assert busy2 is True and "ago" in why2, (busy2, why2)
    # …and OPEN PRs or a fresh dispatch are work in hand even when the queue record says idle: the
    # tool's own fields refuted "the fleet had nothing in hand" (measured: `work_dispatched`
    # PASS/DISPATCHED three lines above `pr_created`'s "nothing in hand")
    d3 = fx("healthy")
    d3["facts"]["log_events"]["headers"] = [{"raw": "=== h load=2 lanes=0 backlog=0 queue=EMPTY ===",
                                             "age_s": 60, "ts": 0, "backlog": 0,
                                             "queue_token": "EMPTY"}]
    d3["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "EMPTY 1792327000", "age_s": 30}
    d3["facts"]["log_events"]["dispatch_ok"] = []
    d3["facts"]["log_events"]["lane_started"] = []
    d3["facts"]["github"]["open_pr_count"] = 2
    busy3, why3 = m._activity(d3["facts"], m.cfg_from_dict(d3["config"]).window_s)
    assert busy3 is True and "open PR" in why3, (busy3, why3)
    d3["facts"]["github"]["open_pr_count"] = 0
    d3["facts"]["github"]["open_prs"] = []
    d3["facts"]["log_events"]["dispatch_ok"] = [{"raw": "[dispatch] load=9 lanes=0 -> 4601",
                                                 "age_s": 60, "issues": [4601]}]
    busy4, why4 = m._activity(d3["facts"], m.cfg_from_dict(d3["config"]).window_s)
    assert busy4 is True and "dispatch" in why4, (busy4, why4)


@test
def test_a_BOOL_is_not_a_count():
    """`isinstance(True, int)` is True, so a payload carrying `prs_created_in_window: true` graded
    PASS/CREATED with "PRs created in the last 3h: True"."""
    m = load()
    cfg = m.cfg_from_dict({})
    for fn, key, name in ((m.check_pr_created, "prs_created_in_window", "pr_created"),
                          (m.check_pr_merged, "prs_merged_in_window", "pr_merged")):
        v = fn({"github": {"ok": True, key: True, "open_pr_count": 3, "open_prs": [],
                           "source": "rest"}}, cfg)
        assert (v.status, v.variant) == (m.INCONCLUSIVE, "GH_COUNT_UNREAD"), (name, v.status, v.variant)


@test
def test_an_ABSENT_auto_armed_key_is_UNREAD_not_unarmed():
    """`pr.get("auto_armed")` reads a MISSING key as a negative, so a row that never carried the field
    produced FAIL/LANDER_MISSING — indistinguishable from a real read of `autoMergeRequest: null`."""
    m = load()
    cfg = m.cfg_from_dict({"repo": "o/r"})
    row = {"number": 5, "draft": False, "merge_state_status": "CLEAN", "checks_green": True,
           "review_decision": "APPROVED", "probed": True}
    facts = {"github": {"ok": True, "open_pr_count": 1, "open_prs": [row], "source": "rest",
                        "page_full": False},
             "log_events": {"headers": [{"raw": "h", "age_s": 5, "backlog": 0,
                                         "queue_token": "READ(3)"}], "armed": [], "railed": [],
                            "repo": [{"repo": "o/r", "age_s": 5}]}}
    v = m.check_landers(facts, cfg)
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "PARTIAL_POPULATION"), (v.status, v.variant)
    # a row that DID read the field and says "not armed" is a real LANDER_MISSING
    row2 = dict(row, auto_armed=False)
    facts["github"]["open_prs"] = [row2]
    v2 = m.check_landers(facts, cfg)
    assert (v2.status, v2.variant) == (m.FAIL, "LANDER_MISSING"), (v2.status, v2.variant)


@test
def test_fleet_activity_reads_the_SAME_queue_token_as_the_queue_checks():
    """`_activity` read the one-refresh-old header, so four checks disagreed about one world: measured,
    `queue_readable` FAILed EMPTY_WITH_LARGE_POOL while `pr_created` answered IDLE_NO_WORK ("the fleet
    had nothing in hand") off the same facts."""
    m = load()
    cfg = m.cfg_from_dict({})
    d = fx("healthy")
    d["facts"]["log_events"]["headers"] = [
        {"raw": "=== Sun Oct 18 07:47:44 EST 2026 load=5 lanes=0 backlog=0 queue=EMPTY(3m) ===",
         "age_s": 180, "ts": 1792327000, "backlog": 0, "queue_token": "EMPTY(3m)", "lanes": 0,
         "load": 5}]
    d["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "READ(223) 1792347000", "age_s": 30}
    d["facts"]["github"]["prs_created_in_window"] = 0
    d["facts"]["github"]["open_pr_count"] = 0
    d["facts"]["github"]["open_prs"] = []
    d["facts"]["log_events"]["dispatch_ok"] = []
    d["facts"]["log_events"]["lane_started"] = []
    busy, why = m._activity(d["facts"])
    assert busy is True, why
    assert "state/queue-state" in why, why
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "pr_created"][0]
    assert (v.status, v.variant) == (m.FAIL, "NO_PR_CREATED"), (v.status, v.variant)


@test
def test_a_FAILED_READ_of_the_queue_record_does_not_pass_through_the_stale_header():
    """The record exists (a readable header token proves the refresh ran and wrote it), so "I could
    not read it" is a MISSING read — not a licence for the one-refresh-old header to answer EMPTY.
    On a `--box` run the read is a remote `cat` that returns rc 127 on timeout, and EACCES/TCC does
    the same locally: a permanent false green, in the direction that must never pass."""
    m = load()
    cfg = m.cfg_from_dict({})
    d = fx("healthy")
    hdr = {"raw": "=== Sun Oct 18 07:47:44 EST 2026 load=10 lanes=0 backlog=0 queue=EMPTY(3m) ===",
           "age_s": 180, "ts": 1792327000, "backlog": 0, "queue_token": "EMPTY(3m)",
           "lanes": 0, "load": 10}
    facts = {"log_events": {"headers": [hdr], "dispatch_ok": [], "dispatch_empty": [],
                            "dispatch_skipped": [], "dispatch_refused": [], "armed": [],
                            "railed": [], "lane_started": [], "lane_failed": []},
             "queue_state": {"path": "q", "ok": False, "raw": None,
                             "error": "cat: Permission denied"}}
    v = [x for x in m.evaluate(facts, cfg) if x.name == "queue_readable"][0]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "QUEUE_STATE_UNREADABLE"), (v.status, v.variant)
    assert "Permission denied" in v.evidence, v.evidence
    w = [x for x in m.evaluate(facts, cfg) if x.name == "work_dispatched"][0]
    assert w.variant != "IDLE_EMPTY_POOL", (w.status, w.variant)
    assert w.status != m.PASS, (w.status, w.variant)
    # an UNPARSEABLE record is authoritative too (one rule, both sources): the harness maps a token
    # outside its vocabulary to UNKNOWN, and its own suite writes exactly this shape
    facts["queue_state"] = {"path": "q", "ok": True, "raw": "garbage here", "age_s": 30}
    v = [x for x in m.evaluate(facts, cfg) if x.name == "queue_readable"][0]
    assert (v.status, v.variant) == (m.FAIL, "QUEUE_NEVER_READ"), (v.status, v.variant, v.evidence)
    # …and the SAME record as the header already answered identically (no two-door grading)
    assert m.parse_queue_token("garbage here")["kind"] == "UNPARSEABLE"


@test
def test_the_RE_MEASURE_guard_abstains_when_the_read_carries_no_ok():
    """`snap.get("ok", True)` defaults an ABSENT read to a successful one, so the guard that exists to
    prevent `launchctl kickstart -k` against a live controller degraded to "empty table = absence"."""
    m = load()
    cfg = m.cfg_from_dict({"o_dir": "/O"})
    for snap in ({}, {"ok": None}, {"ok": False}):
        fp = m._controller_fingerprint(type("M", (), {
            "snapshot_controller": lambda self, snap=snap: snap,
            "log_stat": lambda self: {"age_s": 400.0, "exists": True},
            "o_dir": "/O", "sh": lambda self, cmd, timeout=None: (0, "1")})(), cfg)
        assert fp["ok"] is False, (snap, fp)


@test
def test_the_REST_rollup_does_not_collapse_two_workflows_that_share_a_job_name():
    """The REST check-runs payload has NO `workflowName`, so keying on `app.slug` re-introduced the
    collapse the GraphQL fix removed: measured on one commit, `changes` is published by TWO workflows
    (suites …05368 and …06121), both `app=github-actions`, so a sibling's red `changes` was masked by
    the other's green. The actions RUN id in `details_url` separates them and survives a re-run."""
    m = load()

    def run(name, run_id, concl, started):
        return {"__typename": "CheckRun", "name": name, "app": {"slug": "github-actions"},
                "status": "COMPLETED", "conclusion": concl, "startedAt": started,
                "completedAt": started,
                "detailsUrl": "https://github.com/o/r/actions/runs/%s/job/9" % run_id}

    # two workflows, one job name, and the RED one is the OLDER attempt — the masking direction: a
    # collapsed group would take the newer green and answer "green" over a red commit.
    runs = [run("changes", "111", "FAILURE", "2026-10-18T10:00:00Z"),
            run("changes", "222", "SUCCESS", "2026-10-18T11:00:00Z")]
    assert m.rollup_is_green(runs) is False, "a red sibling workflow was masked by a green one"
    # …and the newest is red too, which no grouping can rescue
    runs = [run("changes", "111", "SUCCESS", "2026-10-18T10:00:00Z"),
            run("changes", "222", "FAILURE", "2026-10-18T11:00:00Z")]
    assert m.rollup_is_green(runs) is False, "a red newest attempt was ignored"
    # the same workflow's re-run still groups: the NEWEST attempt decides
    runs = [run("changes", "111", "FAILURE", "2026-10-18T10:00:00Z"),
            run("changes", "111", "SUCCESS", "2026-10-18T11:00:00Z")]
    assert m.rollup_is_green(runs) is True, m.rollup_is_green(runs)


@test
def test_an_empty_batch_line_cannot_be_vouched_for_by_any_spawn():
    """`batch_issues and …` switched the cross-batch guard OFF for an empty issue list, so a spawn for
    an issue in NO batch vouched for it: measured "0 issue(s) dispatched" + PASS/DISPATCHED + exit 0.
    A batch line that names no issue cannot have spawned one."""
    m = load()
    cfg = m.cfg_from_dict({})
    facts = {"log_events": {
        "headers": [{"raw": "=== Sun Oct 18 07:47:44 EST 2026 load=40 lanes=2 backlog=9 "
                            "queue=READ(223)(9m) ===", "age_s": 60, "ts": 1792327000,
                     "backlog": 9, "queue_token": "READ(223)(9m)", "lanes": 2, "load": 40}],
        "dispatch_ok": [{"raw": "[dispatch] load=40 lanes=2 ->  ", "issues": [],
                         "issue_count": 0, "age_s": 60, "ts": 1792327000}],
        "lane_started": [{"raw": "#9999: lane-9 (implement+PR)", "issue": 9999, "lane": 9,
                          "age_s": 60, "ts": 1792327000}],
        "lane_failed": [], "dispatch_refused": [], "dispatch_empty": [], "dispatch_skipped": [],
        "armed": [], "railed": []}}
    v = m.check_work_dispatched(facts, cfg)
    assert v.status != m.PASS, (v.status, v.variant, v.evidence)
    assert v.variant == "DISPATCH_UNCONFIRMED", (v.status, v.variant)


@test
def test_an_UNREAD_oom_protection_value_is_UNEVALUABLE_not_unprotected():
    """`known` silently drops None (EACCES on another user's /proc/<pid>/oom_score_adj, or a
    timed-out probe — any canary not running as the daemon's owner), so with every value unread the
    check claimed PROTECTION_ABSENT: an absence built from a failed read."""
    m = load()
    cfg = m.cfg_from_dict({})
    pane = {"ok": True, "protection_supported": True, "cmd": "cmux-tui",
            "pids": [{"pid": 11, "oom_score_adj": None}, {"pid": 12, "oom_score_adj": None}]}
    v = m.check_pane_daemon({"pane": pane}, cfg)
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "PROTECTION_UNEVALUABLE"), (v.status, v.variant)
    # one readable negative + one unread is NOT "all protected": still not green
    pane["pids"] = [{"pid": 11, "oom_score_adj": -900}, {"pid": 12, "oom_score_adj": None}]
    v = m.check_pane_daemon({"pane": pane}, cfg)
    assert v.status == m.INCONCLUSIVE, (v.status, v.variant)
    # a READ value of 0 is still the failure this check exists for
    pane["pids"] = [{"pid": 11, "oom_score_adj": 0}]
    v = m.check_pane_daemon({"pane": pane}, cfg)
    assert (v.status, v.variant) == (m.FAIL, "PROTECTION_ABSENT"), (v.status, v.variant)


@test
def test_an_ok_disk_read_with_no_number_is_UNREAD_not_zero_gib():
    """`(avail_bytes or 0)` turned a missing field into "disk 0.0 GiB free" — a manufactured OOM
    emergency on the check whose FAIL must mean one."""
    m = load()
    cfg = m.cfg_from_dict({})
    v = m.check_headroom({"headroom": {"disk": {"ok": True, "used_pct": 40.0, "mount": "/"},
                                       "mem": {"ok": True, "avail_mb": 9000, "source": "d"}}}, cfg)
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "PROBE_UNREADABLE"), (v.status, v.variant)
    assert "avail_bytes" in v.evidence, v.evidence


@test
def test_the_WIRED_machine_carries_o_dir_so_the_heartbeat_leg_works():
    """The respawn proof is `log_advanced or hb_advanced`, and `_heartbeat_epoch` needs `machine.o_dir`.
    `main` wired `log_path`, `tail_lines` and `controller_paths` but NOT `o_dir` (only `collect_live`
    set it), so the heartbeat leg was DEAD in the shipped CLI while the suite stayed green — its test
    hands the function a fake that already carries `o_dir`. On a high-load cell a successful respawn
    cannot write the log inside the 40 s bound, so the failure mode is a SUCCESSFUL respawn reported
    and SENT as `RESPAWN DID NOT TAKE`."""
    m = load()
    cfg = m.cfg_from_dict({"o_dir": "/O"})
    mach = m.build_machine(cfg)
    assert mach.o_dir == "/O", mach.o_dir
    assert mach.log_path == cfg.log_path and mach.tail_lines == 6000
    # …and the heartbeat epoch is actually reachable through that object
    seen = {}

    def fake_sh(cmd, timeout=None):
        seen["cmd"] = cmd
        return (0, "1792344305")

    mach.sh = fake_sh
    assert m._heartbeat_epoch(mach) == 1792344305, seen.get("cmd")
    assert "heartbeat" in seen["cmd"], seen["cmd"]


@test
def test_a_lander_decision_from_ANOTHER_repo_does_not_vouch_for_this_repos_PR():
    """`armed`/`railed` were matched to PRs by NUMBER alone and the log's own repo was never compared
    with `--repo`. Measured on this Mac: the controller log names daniel-ospina/tortoise 972 times and
    daniel-ospina/agent-infra zero times, its plist says OR=tortoise — and `--repo agent-infra` read
    PASS/LANDERS_ARMED off tortoise's rail line. Mirror direction: a false LANDER_EXPIRED."""
    m = load()
    d = fx("healthy")
    prs = [{"number": 900, "merge_state_status": "CLEAN", "checks_green": True, "probed": True,
            "auto_armed": False, "draft": False, "review_decision": "APPROVED"}]
    d["facts"]["github"].update({"open_prs": prs, "open_pr_count": 1})
    d["facts"]["log_events"]["railed"] = [
        {"raw": "#900 PENDING (rail mode)", "pr": 900, "age_s": 60, "ts": 1792327000}]
    d["facts"]["log_events"]["armed"] = []
    d["facts"]["log_events"]["repo"] = [
        {"raw": "[req] daniel-ospina/tortoise: required checks from branch protection",
         "repo": "daniel-ospina/tortoise", "age_s": 60, "ts": 1792327000}]
    cfg = m.cfg_from_dict({"repo": "daniel-ospina/agent-infra"})
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "landers"][0]
    # the rail line belongs to tortoise → it cannot arm agent-infra's #900
    assert v.status != m.PASS, (v.status, v.variant, v.evidence)
    assert "ANOTHER REPO" in v.evidence, v.evidence
    assert "tortoise" in v.evidence, v.evidence
    # the same log for its OWN repo vouches normally
    cfg2 = m.cfg_from_dict({"repo": "daniel-ospina/tortoise"})
    v = [x for x in m.evaluate(d["facts"], cfg2) if x.name == "landers"][0]
    assert (v.status, v.variant) == (m.PASS, "LANDERS_ARMED"), (v.status, v.variant, v.evidence)
    # the ARMED direction is the same defect: a foreign repo's `auto-armed` line cannot arm this PR
    d["facts"]["log_events"]["railed"] = []
    d["facts"]["log_events"]["armed"] = [
        {"raw": "#900 auto-armed", "pr": 900, "age_s": 60, "ts": 1792327000}]
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "landers"][0]
    # MISSING, not EXPIRED: a foreign line may neither arm this PR (that would be a false PASS) nor
    # claim its lander expired (that would be a false alarm). Pinning the VARIANT is what makes the
    # difference between the two guards observable at all.
    assert (v.status, v.variant) == (m.FAIL, "LANDER_MISSING"), (v.status, v.variant, v.evidence)
    # …and for the log's OWN repo that same line is a genuine silent expiry (log says armed,
    # GitHub says not armed) — which is what makes the cross-repo case a false verdict either way
    v = [x for x in m.evaluate(d["facts"], cfg2) if x.name == "landers"][0]
    assert (v.status, v.variant) == (m.FAIL, "LANDER_EXPIRED"), (v.status, v.variant)
    d["facts"]["log_events"]["armed"] = []
    d["facts"]["log_events"]["railed"] = [
        {"raw": "#900 PENDING (rail mode)", "pr": 900, "age_s": 60, "ts": 1792327000}]
    # …and a log that names no repo keeps working (identity unknown is not a mismatch)
    d["facts"]["log_events"]["repo"] = []
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "landers"][0]
    assert (v.status, v.variant) == (m.PASS, "LANDERS_ARMED"), (v.status, v.variant, v.evidence)


@test
def test_an_EMPTY_process_or_launchd_read_is_a_FAILED_READ_not_absence():
    """`ps -Ao` prints at least one row on any live system, so empty-with-rc0 is a broken probe — and
    reading it as "no such process" reached CONTROLLER_ABSENT, the ONLY state that respawns. The
    re-measure guard uses the same probe and the same polarity, so it could not save it. This is the
    doctrine `_json_list` already states for gh ("EMPTY STDOUT IS A FAILED READ")."""
    m = load()
    cfg = m.cfg_from_dict({"o_dir": "/O", "controller_paths": ["/O/orch-loop.sh"]})
    mach = m.Machine(None)
    mach.controller_paths = ["/O/orch-loop.sh"]
    mach.sh = lambda cmd, timeout=None: (0, "")
    assert mach.snapshot_controller()["ok"] is False, mach.snapshot_controller()
    assert mach.snapshot_pane()["ok"] is False, mach.snapshot_pane()
    assert mach.launchd_state("x")["loaded"] is None, mach.launchd_state("x")
    # a real table still parses
    mach.sh = lambda cmd, timeout=None: (
        (0, "  1     0 /sbin/launchd\n  2     1 /bin/zsh") if "ps -Ao pid=,ppid=" in cmd
        else (0, "  PANEL  0  com.eldato.orchestrator-loop"))
    assert mach.snapshot_controller()["ok"] is True
    # and the predicate must not resume on an unreadable table: it ABSTAINS, never respawns
    facts = {"controller": {"ok": False, "pids": [], "error": "empty process table (rc=0)"},
             "launchd": {"loaded": False, "pid": None}, "log": {"exists": True, "age_s": 5.0},
             "log_events": {"headers": [{"raw": "h", "age_s": 5.0, "ts": 1}]}}
    v = m.check_controller_cycling(facts, cfg)
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "PROCESS_TABLE_UNREADABLE"), (v.status, v.variant)
    assert v.variant not in m.RESPAWN_TRIGGERS, v.variant


@test
def test_an_ABSENT_controller_ok_is_a_MISSING_read_not_an_empty_table():
    """Every other collector gate in this file is `is not True`; `controller` used `is False`, so an
    absent key read as a successful read of an empty table — and an empty table is the ONLY state
    that respawns. The fixtures had no `ok` key at all, which is how it stayed invisible."""
    m = load()
    cfg = m.cfg_from_dict({})
    d = fx("healthy")
    del d["facts"]["controller"]["ok"]
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "controller_cycling"][0]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "PROCESS_TABLE_UNREADABLE"), (v.status, v.variant)
    d = fx("healthy")
    del d["facts"]["pane"]["ok"]
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "pane_daemon"][0]
    assert v.status == m.INCONCLUSIVE, (v.status, v.variant)


@test
def test_a_bad_fixture_path_is_a_USAGE_error_not_the_FAIL_exit_code():
    """`run_static` raises FixtureError and `main` never caught it, so a typo'd --fixture printed a
    traceback and exited 1 — the code the contract reserves for "at least one check FAILed". A
    scheduler reads that as "the fleet failed" when nothing was evaluated at all."""
    m = load() if False else None      # (the CLI is driven through run_cli below)
    rc, out, err = run_cli(["--static", "--fixture", "/tmp/oc-definitely-missing-%d.json" % os.getpid()])
    assert rc == 3, (rc, out[-200:], err[-200:])
    assert "Traceback" not in err, err[-300:]


@test
def test_a_TRUNCATED_merged_page_does_not_read_as_nothing_merged():
    """`gh pr list --state merged` is CREATED-desc (measured), so `--limit 100` bounds creation, not
    merge recency: the 100 newest-created merged PRs span 7.6 days here, so a PR created 8+ days ago
    and merged an hour ago sits outside the page and the count reads 0 — a false NO_PR_MERGED."""
    m = load()
    d = fx("healthy")
    gh = d["facts"]["github"]
    gh["prs_merged_in_window"] = 0
    gh["merged_page_full"] = True
    cfg = m.cfg_from_dict(d.get("config") or {})
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "pr_merged"][0]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "MERGED_SURFACE_TRUNCATED"), (v.status, v.variant)
    # an in-window merge on a full page is still a PASS: the datum is positive evidence
    gh["prs_merged_in_window"] = 3
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "pr_merged"][0]
    assert (v.status, v.variant) == (m.PASS, "MERGED"), (v.status, v.variant)
    # and an un-truncated empty read is unchanged (still FAIL / IDLE as the fixture declared)
    gh["merged_page_full"] = False
    gh["prs_merged_in_window"] = 0
    assert [x for x in m.evaluate(d["facts"], cfg) if x.name == "pr_merged"][0].status != m.PASS


@test
def test_a_lane_spawn_from_ANOTHER_batch_does_not_vouch_for_this_one():
    """⛔ THE SPAWN MUST BELONG TO THE BATCH BEING GRADED.

    `started` came from every lane line in the window, so an OLDER cycle's spawn vouched for the
    newest batch. Measured input: previous batch (540s ago) spawned 4400/4401, newest batch (60s ago)
    spawned nothing → PASS/DISPATCHED and exit 0 — the silently-failed spawn this check exists for,
    because `dispatch-merge.sh` has no `else` on its `tmux new-session` branch.
    """
    m = load()
    cfg = m.cfg_from_dict({})
    hdr = {"raw": "=== Sun Oct 18 07:47:44 EST 2026 load=50 lanes=2 backlog=9 queue=READ(223)(9m) ===",
           "age_s": 60, "ts": 1792327000, "backlog": 9, "queue_token": "READ(223)(9m)",
           "lanes": 2, "load": 50}
    facts = {"log_events": {
        "headers": [hdr],
        "dispatch_ok": [
            {"raw": "[dispatch] load=50 lanes=2 -> 4400 4401", "issues": [4400, 4401],
             "issue_count": 2, "age_s": 540, "ts": 1792326520},
            {"raw": "[dispatch] load=50 lanes=2 -> 5001 5002", "issues": [5001, 5002],
             "issue_count": 2, "age_s": 60, "ts": 1792327000}],
        "lane_started": [
            {"raw": "#4400: lane-4400 (implement+PR)", "issue": 4400, "lane": 4400,
             "age_s": 540, "ts": 1792326520},
            {"raw": "#4401: lane-4401 (implement+PR)", "issue": 4401, "lane": 4401,
             "age_s": 540, "ts": 1792326520}],
        "lane_failed": [], "dispatch_refused": [], "dispatch_empty": [], "dispatch_skipped": [],
        "armed": [], "railed": []}}
    v = m.check_work_dispatched(facts, cfg)
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "DISPATCH_UNCONFIRMED"), \
        (v.status, v.variant, v.evidence)
    assert "DIFFERENT batch" in v.evidence, v.evidence
    # a spawn for THIS batch, issued no earlier than the batch line, is the proof
    facts["log_events"]["lane_started"].append(
        {"raw": "#5001: lane-5001 (implement+PR)", "issue": 5001, "lane": 5001,
         "age_s": 60, "ts": 1792327000})
    v = m.check_work_dispatched(facts, cfg)
    assert (v.status, v.variant) == (m.PASS, "DISPATCHED"), (v.status, v.variant, v.evidence)
    assert "#5001 lane-5001" in v.evidence, v.evidence
    # …and a spawn that PRECEDES the batch line it is credited to is not proof either
    facts["log_events"]["lane_started"] = [
        {"raw": "#5001: lane-5001 (implement+PR)", "issue": 5001, "lane": 5001,
         "age_s": 300, "ts": 1792326700}]        # inside the window, but OLDER than the batch line
    v = m.check_work_dispatched(facts, cfg)
    assert v.status == m.INCONCLUSIVE, (v.status, v.variant, v.evidence)


@test
def test_the_QUEUE_STATE_record_outranks_a_header_that_is_one_refresh_old():
    """⛔ THE HEADER TOKEN IS ALWAYS ONE REFRESH OLD AND THE STATE RECORD WAS NEVER PARSED.

    `orch-loop.sh` writes the cycle header at the TOP of a cycle and runs `refresh-candidates.sh`
    later in the same cycle, so `state/queue-state` is always the newer record — only its EPOCH was
    read. A header `EMPTY(3m)` beside a 40s-old `state/queue-state: UNREADABLE` therefore graded
    PASS/READABLE + PASS/IDLE_EMPTY_POOL and exit 0 with no message: agent-infra#1931 recorded as
    health. Measured on this box: header `queue=READ(218)` beside `state/queue-state: PARTIAL(P2-...)`.
    """
    m = load()
    cfg = m.cfg_from_dict({})
    hdr = {"raw": "=== Sun Oct 18 07:47:44 EST 2026 load=10 lanes=0 backlog=0 queue=EMPTY(3m) ===",
           "age_s": 180, "ts": 1792327000, "backlog": 0, "queue_token": "EMPTY(3m)",
           "lanes": 0, "load": 10}
    base = {"log_events": {"headers": [hdr], "dispatch_ok": [], "dispatch_empty": [],
                           "dispatch_skipped": [], "dispatch_refused": [], "armed": [],
                           "railed": [], "lane_started": [], "lane_failed": []}}

    def facts(qs):
        f = dict(base)
        f["queue_state"] = qs
        return f

    # the newer state record says UNREADABLE → the header's EMPTY is stale and must not be graded
    f = facts({"path": "q", "ok": True, "raw": "UNREADABLE 1792343000", "age_s": 40})
    v = [x for x in m.evaluate(f, cfg) if x.name == "queue_readable"][0]
    assert (v.status, v.variant) == (m.FAIL, "QUEUE_UNREADABLE"), (v.status, v.variant, v.evidence)
    assert "state/queue-state" in v.evidence, v.evidence
    # …and a blind refresh is NOT "nothing to do": work_dispatched must not read the stale EMPTY
    w = [x for x in m.evaluate(f, cfg) if x.name == "work_dispatched"][0]
    assert w.status != m.PASS, (w.status, w.variant, w.evidence)
    assert "IDLE_EMPTY_POOL" not in w.variant, w.variant
    # an OLDER state record does not outrank the header (the documented shape still works)
    f = facts({"path": "q", "ok": True, "raw": "READ(223) 1792326000", "age_s": 1200})
    v = [x for x in m.evaluate(f, cfg) if x.name == "queue_readable"][0]
    assert v.status == m.PASS, (v.status, v.variant, v.evidence)
    # ⛔ AN UNREADABLE RECORD WITH NO EPOCH IS STILL AUTHORITATIVE. Requiring an age demoted it and
    # let the one-refresh-old header decide — the harness prints a bare token exactly when its epoch
    # field is missing or torn, so this shape is real, and it reproduced the PASS/exit-0 it fixed.
    f = facts({"path": "q", "ok": True, "raw": "UNREADABLE", "age_s": None})
    assert m.authoritative_queue_token(f, hdr)[2] == "state/queue-state"
    v = [x for x in m.evaluate(f, cfg) if x.name == "queue_readable"][0]
    assert (v.status, v.variant) == (m.FAIL, "QUEUE_UNREADABLE"), (v.status, v.variant, v.evidence)
    # An EMPTINESS read with NO age anywhere establishes nothing: STATE_FROZEN, not merely "loses
    # the contest". (An unaged record whose header token DOES carry `(3m)` is still aged — the two
    # clocks are read together and the older one wins — which is why the token below carries none.)
    f = facts({"path": "q", "ok": True, "raw": "EMPTY", "age_s": None})
    f["log_events"]["headers"] = [dict(hdr, raw="=== Sun Oct 18 07:47:44 EST 2026 load=10 lanes=0 "
                                              "backlog=0 queue=EMPTY ===", queue_token="EMPTY")]
    v = [x for x in m.evaluate(f, cfg) if x.name == "queue_readable"][0]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "STATE_FROZEN"), (v.status, v.variant, v.evidence)


@test
def test_an_UNPARSEABLE_memory_probe_is_INCONCLUSIVE_not_zero_free_mib():
    """The awk `END` block emitted `(free+inact+spec)*ps` unconditionally, so a `vm_stat` whose
    wording moved produced `darwin 0` — and 0 MiB is FAIL/BELOW_FLOOR, i.e. an unreadable probe
    reported as an OOM emergency, on the one check whose FAIL is supposed to mean one."""
    m = load()
    mach = m.Machine(None)
    seen = {}

    def fake_sh(cmd, timeout=None):
        if "df -k" in cmd:
            return (0, "/dev/disk1 100 900000000 400000000 40% /")
        seen["mem_cmd"] = cmd
        return (0, "darwin UNKNOWN")

    mach.sh = fake_sh
    hr = mach.headroom("/")
    assert "UNKNOWN" in seen["mem_cmd"] and "seen" in seen["mem_cmd"], seen["mem_cmd"]
    assert hr["disk"]["ok"] is True, hr["disk"]
    assert hr["mem"]["ok"] is False, hr["mem"]        # ← the whole point: unread, not zero
    # …and the emitted awk must actually DO it, not merely contain the words. Run the program the
    # command carries against a REAL vm_stat-shaped input, with the fields it SUMS reworded: grepping
    # the command for "UNKNOWN" cannot tell `if (0) print "darwin UNKNOWN"` from the real guard.
    prog = re.search(r"vm_stat \| awk '(.*?)'; fi", seen["mem_cmd"], re.S).group(1)
    full = ("Mach Virtual Memory Statistics: (page size of 16384 bytes)\n"
            "Pages free:                          100.\n"
            "Pages inactive:                      200.\n"
            "Pages speculative:                    50.\n")
    reworded = full.replace("Pages inactive", "Pages idle-ish").replace(
        "Pages speculative", "Pages guessed")
    run = lambda text: subprocess.run(["awk", prog], input=text, capture_output=True,
                                      text=True).stdout.strip()
    assert run(full).startswith("darwin "), run(full)
    assert run(full) != "darwin UNKNOWN", run(full)
    assert run(reworded) == "darwin UNKNOWN", run(reworded)
    v = m.check_headroom({"headroom": hr}, m.cfg_from_dict({}))
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "PROBE_UNREADABLE"), (v.status, v.variant)

    # a real reading still parses
    mach.sh = lambda cmd, timeout=None: (
        (0, "/dev/disk1 100 900000000 400000000 40% /") if "df -k" in cmd else (0, "darwin 8192"))
    hr = mach.headroom("/")
    assert hr["mem"] == {"ok": True, "avail_mb": 8192.0, "source": "darwin"}, hr["mem"]
    assert m.check_headroom({"headroom": hr}, m.cfg_from_dict({})).status == m.PASS


@test
def test_an_ABSENT_open_pr_count_is_a_missing_read_not_agreement():
    """The self-consistency guard is `isinstance(count, int) AND count != len(prs)` — so an ABSENT
    count SKIPPED the guard and the check reasoned over a population nothing had confirmed."""
    m = load()
    d = fx("healthy")
    cfg = m.cfg_from_dict(d.get("config") or {})
    del d["facts"]["github"]["open_pr_count"]
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "landers"][0]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "GH_UNREADABLE"), (v.status, v.variant)
    assert "open_pr_count" in v.evidence, v.evidence


@test
def test_a_rollup_AT_the_graphql_page_bound_is_unprobed():
    """`gh pr list --json statusCheckRollup` builds `contexts(first:100)` with no pagination and drops
    `pageInfo`, while the REST fallback DOES read `total_count`. A full page is therefore not a
    rollup: a red check beyond the bound would read green and ADD a lander candidate."""
    m = load()
    green = [{"__typename": "CheckRun", "name": "c%d" % i, "workflowName": "CI", "status": "COMPLETED",
              "conclusion": "SUCCESS", "startedAt": "2026-10-18T10:00:00Z", "completedAt": None,
              "detailsUrl": "u"} for i in range(100)]
    assert m.rollup_is_green(green) is True          # the predicate alone cannot see the bound…
    assert m.rollup_truncated(green) is True and m.rollup_truncated(green[:99]) is False
    # …so the COLLECTOR must apply it, and the row must come out UNPROBED (probed=False), not PASS
    real = m._run_gh

    def fake(argv):
        cmd = " ".join(argv)
        if "--state open" in cmd:
            return 0, json.dumps([{"number": 950, "mergeStateStatus": "CLEAN",
                                   "autoMergeRequest": {"x": 1}, "isDraft": False,
                                   "statusCheckRollup": green, "reviewDecision": "APPROVED"}])
        return 0, "[]"

    try:
        m._run_gh = fake
        gh = m.collect_github("o/r", m.Cfg(), now=1792327664.0)
    finally:
        m._run_gh = real
    assert gh["ok"] is True and gh["source"] == "graphql", (gh.get("source"), gh.get("error"))
    row = gh["open_prs"][0]
    assert row["checks_green"] is None and row["probed"] is False, row
    # …which keeps it OUT of the "every green PR is armed" population rather than in it
    facts = fx("healthy")["facts"]
    facts["github"] = gh
    v = [x for x in m.evaluate(facts, m.cfg_from_dict(fx("healthy")["config"]))
         if x.name == "landers"][0]
    assert v.status == m.INCONCLUSIVE and v.variant == "PARTIAL_POPULATION", (v.status, v.variant)


@test
def test_a_dispatch_INTENT_is_not_a_dispatch():
    """⛔ THE BATCH LINE IS AN INTENT, AND THIS CHECK EXISTS TO GRADE THE OUTCOME.

    `orch-loop.sh` echoes `[dispatch] load=… -> N` and only THEN calls `dispatch-merge.sh`, whose
    spawn fails in ways that print their own lines (`#N: worktree add failed (branch exists?) —
    skipping`, `#N: chain-N could NOT be started`) or print NOTHING at all (`tmux new-session`'s
    branch has no else). The disambiguating lines sit in the same tail and were never parsed, so the
    check that matters most returned PASS/DISPATCHED + exit 0 for a fleet that spawned nothing.
    """
    m = load()
    cfg = m.cfg_from_dict({})
    ev = lambda bucket, **kw: dict({"raw": "", "age_s": 30, "ts": 1792327000}, **kw)

    def facts(lane_started, lane_failed):
        return {"log_events": {
            "headers": [ev("headers", raw="=== Sun Oct 18 07:47:44 EST 2026 load=90 lanes=2 "
                                        "backlog=47 queue=READ(223)(9m) ===", backlog=47,
                           queue_token="READ(223)(9m)", lanes=2, load=90)],
            "dispatch_ok": [dict(ev("dispatch_ok", raw="[dispatch] load=90 lanes=2 -> 1981 1982"),
                                 issues=[1981, 1982], issue_count=2)],
            "lane_started": lane_started, "lane_failed": lane_failed,
            "dispatch_refused": [], "dispatch_empty": [], "dispatch_skipped": [],
            "armed": [], "railed": []}}

    started = [dict(ev("s", raw="#1982: lane-2 (implement+PR)"), issue=1982, lane=2)]
    failed = [dict(ev("f", raw="#1981: worktree add failed (branch exists?) — skipping"),
                   issue=1981, reason="worktree add failed (branch exists?) — skipping")]

    # every spawn failed → the intent is refuted by the outcome
    v = m.check_work_dispatched(facts([], failed), cfg)
    assert (v.status, v.variant) == (m.FAIL, "NO_LANE_STARTED"), (v.status, v.variant, v.evidence)
    assert "worktree add failed" in v.evidence, v.evidence
    # no spawn outcome at all (a truncated tail looks exactly like this) → abstain, never green
    v = m.check_work_dispatched(facts([], []), cfg)
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "DISPATCH_UNCONFIRMED"), (v.status, v.reason)
    # a lane actually started → PASS, and the spawn is NAMED in the evidence
    v = m.check_work_dispatched(facts(started, failed), cfg)
    assert (v.status, v.variant) == (m.PASS, "DISPATCHED"), (v.status, v.variant)
    assert "#1982 lane-2 (implement+PR)" in v.evidence, v.evidence
    # …and a failed spawn beside a successful one is still PRINTED: a pass may not hide it
    assert "lane spawn FAILED" in v.evidence, v.evidence
    # ⛔ A START REFUTED BY ITS OWN FAILURE LINE IS NOT A LIVE LANE: `dispatch-merge.sh` echoes the
    # lane line and can then print `chain-N could NOT be started - stopping lane-N`, killing it. The
    # PASS count must be the OUTCOME count, never the batch line's INTENT count.
    assert "1 lane(s) STARTED" in v.evidence and "batch INTENT: 2" in v.evidence, v.evidence
    killed = [dict(ev("s", raw="#1982: lane-2 (implement+PR)"), issue=1982, lane=2)]
    refuted = [dict(ev("f", raw="#1982: chain-1982 could NOT be started — stopping lane-1982 "
                              "(its PR would never be merged)"), issue=1982,
                     reason="chain-1982 could NOT be started")]
    v = m.check_work_dispatched(facts(killed, refuted), cfg)
    assert (v.status, v.variant) == (m.FAIL, "NO_LANE_STARTED"), (v.status, v.variant, v.evidence)


@test
def test_the_spawn_line_shapes_the_harness_actually_prints_are_parsed():
    """The regexes are the load-bearing part: they must match the harness's OWN strings, including
    the em-dash in `worktree add failed (branch exists?) — skipping`."""
    m = load()
    log = [
        "=== Sun Oct 18 07:47:44 EST 2026 load=90 lanes=2 backlog=47 queue=READ(223)(9m) ===",
        "[dispatch] load=90 lanes=2 -> 1981 1982",
        "#1981: worktree add failed (branch exists?) \u2014 skipping",
        "#1982: lane-3 (implement+PR)",
    ]
    ev = m.parse_log(log)
    assert [e["issue"] for e in ev["lane_started"]] == [1982], ev["lane_started"]
    assert [e["issue"] for e in ev["lane_failed"]] == [1981], ev["lane_failed"]
    # the un-asked question: a chain that could not be started is ALSO a spawn failure
    ev2 = m.parse_log(["=== Sun Oct 18 07:47:44 EST 2026 load=90 lanes=2 backlog=47 queue=READ(1) ===",
                       "#4242: chain-4242 could NOT be started"])
    assert [e["issue"] for e in ev2["lane_failed"]] == [4242], ev2["lane_failed"]


@test
def test_a_cycle_header_OLDER_than_the_window_is_not_a_cycle():
    """The window bound on cycle headers was unpinned: a mutation that dropped it (counting every
    header ever seen) survived the whole suite. A fresh log mtime plus one ancient header is a
    controller that started once and wedged, which is the exact shape LOG_NO_CYCLE exists for."""
    m = load()
    d = fx("healthy")
    d["facts"]["log"]["age_s"] = 20.0                     # the log IS advancing
    d["facts"]["log_events"]["headers"][0]["age_s"] = 99999.0   # …by a header older than the window
    cfg = m.cfg_from_dict(d.get("config") or {})
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "controller_cycling"][0]
    assert (v.status, v.variant) == (m.FAIL, "LOG_NO_CYCLE"), (v.status, v.variant, v.evidence)


@test
def test_the_queue_token_AGE_is_read_with_ITS_OWN_multiplier():
    """`READ(223)(9m)` is nine MINUTES. The multiplier was unpinned — `m` silently became seconds,
    which turns a stale refresh into a fresh one, i.e. exactly the false green this token exists to
    prevent."""
    m = load()
    assert m.parse_queue_token("READ(223)(9m)")["token_age_s"] == 540.0
    assert m.parse_queue_token("READ(223)(9s)")["token_age_s"] == 9.0
    assert m.parse_queue_token("READ(223)(2h)")["token_age_s"] == 7200.0
    assert m.parse_queue_token("READ(223)")["token_age_s"] is None
    # …and it must actually REACH a verdict. The multiplier is load-bearing for EMPTINESS: an
    # OLD empty read beside an unreadable queue state is the only age the check has, and
    # past the limit "the pool is empty" is a claim about then — STATE_FROZEN, never READABLE.
    d = fx("healthy")
    # a READABLE, FRESH record (so the header token is the graded source and its own `(NNm)` suffix is
    # the clock this test is about; the two ages then differ only by the multiplier)
    d["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "EMPTY 1792327000", "age_s": 60.0}
    # 120m, not 90m: 90m is EXACTLY the 5400s limit, and the boundary is deliberately inclusive
    d["facts"]["log_events"]["headers"][0]["queue_token"] = "EMPTY(120m)"
    d["facts"]["log_events"]["headers"][0]["backlog"] = 0
    cfg = m.cfg_from_dict(d.get("config") or {})
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "queue_readable"][0]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "STATE_FROZEN"), (v.status, v.variant, v.evidence)
    # the SAME token read as seconds (90s) is inside the limit: the `m`/`s` multiplier is what makes
    # the difference, so the assertion above cannot be satisfied by ignoring the suffix.
    d["facts"]["log_events"]["headers"][0]["queue_token"] = "EMPTY(90s)"
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "queue_readable"][0]
    assert v.variant != "STATE_FROZEN", (v.status, v.variant, v.evidence)


@test
def test_a_DRAFT_PR_is_COUNTED_as_skipped_not_dropped_silently():
    """A draft row hit `continue` before the skip bookkeeping, so it appeared NOWHERE: the
    population arithmetic did not reconcile and the `DRAFT` entry in KNOWN_NON_MERGEABLE was
    unreachable. Silent omission is the failure mode; the count is the fix."""
    m = load()
    d = fx("healthy")
    prs = d["facts"]["github"]["open_prs"]
    prs.append({"number": 4321, "draft": True, "probed": True, "mergeable": "MERGEABLE",
                "merge_state": "CLEAN", "armed_in_window": True})
    d["facts"]["github"]["open_pr_count"] = len(prs)
    cfg = m.cfg_from_dict(d.get("config") or {})
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "landers"][0]
    assert "4321:DRAFT" in v.evidence, v.evidence


@test
def test_each_headroom_floor_is_graded_ON_ITS_OWN():
    """The shipped low-headroom fixture has disk AND memory under floor, so either comparison alone
    still produced a FAIL — neither floor was pinned, and deleting one comparison was invisible."""
    m = load()
    cfg = m.cfg_from_dict({})
    ok_disk = {"ok": True, "avail_bytes": int(400 * (1 << 30)), "used_pct": 40.0, "mount": "/"}
    ok_mem = {"ok": True, "avail_mb": 9000, "source": "darwin"}
    low_disk = {"ok": True, "avail_bytes": int(2 * (1 << 30)), "used_pct": 99.0, "mount": "/"}
    low_mem = {"ok": True, "avail_mb": 50, "source": "darwin"}
    for disk, mem, bad, good in ((low_disk, ok_mem, "disk", "memory"),
                                 (ok_disk, low_mem, "memory", "disk")):
        v = m.check_headroom({"headroom": {"disk": disk, "mem": mem}}, cfg)
        assert v.status == m.FAIL and v.variant == "BELOW_FLOOR", (v.status, v.variant)
        # ONLY the floor that is actually under is named in the reason: that is what pins each
        # comparison independently, so deleting either one is visible.
        named = v.detail.split("below the configured floor: ")[-1]
        assert bad in named and good not in named, (bad, named)
    # and a PASS must PRINT both numbers, not assert "fine"
    v = m.check_headroom({"headroom": {"disk": ok_disk, "mem": ok_mem}}, cfg)
    assert v.status == m.PASS and "GiB free" in v.evidence and "MiB available" in v.evidence, \
        v.evidence


@test
def test_landers_never_reports_green_over_PR_it_did_not_read():
    """`_collect_rest` stops probing at `rest_probe_max`, and a failed check-runs call also yields
    probed=False. A probed-and-armed PR used to end the question: PASS, with the unread PRs appearing
    nowhere — a false green on the one check that exists to catch a lander expiring on a PR nobody
    looked at."""
    m = load()
    d = fx("healthy")
    prs = [{"number": 1, "merge_state_status": "CLEAN", "checks_green": True,
            "auto_armed": True, "draft": False, "probed": True}]
    prs += [{"number": n, "merge_state_status": None, "checks_green": None,
             "auto_armed": False, "draft": False, "probed": False} for n in range(2, 17)]
    d["facts"]["github"]["open_prs"] = prs
    d["facts"]["github"]["open_pr_count"] = len(prs)
    cfg = m.cfg_from_dict(d["config"])
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "landers"][0]
    assert v.status == m.INCONCLUSIVE, (v.status, v.variant, v.evidence)
    assert v.variant == "PARTIAL_POPULATION", v.variant
    assert "UNPROBED" in v.evidence and "[2, 3" in v.evidence, v.evidence


@test
def test_a_MISSING_github_surface_is_not_a_successful_read():
    """Allow-list polarity, the same rule `rollup_is_green` uses: `is False` reads an ABSENT `ok` as
    a good read, so a facts dict with no github surface made `landers` PASS on "open PRs: 0"."""
    m = load()
    d = fx("healthy")
    del d["facts"]["github"]
    cfg = m.cfg_from_dict(d["config"])
    got = dict((v.name, (v.status, v.variant)) for v in m.evaluate(d["facts"], cfg))
    for name in ("pr_created", "pr_merged", "landers"):
        assert got[name][0] == m.INCONCLUSIVE, (name, got[name])
        assert got[name][1] == "GH_UNREADABLE", (name, got[name])

    # …and the SAME must hold when the surface says so EXPLICITLY: `ok: False` with a row attached is
    # a refused read, not a population. (`is False` polarity, `is not True` — the other half of the
    # rule: an absent key and an explicit refusal are both "no read".)
    d2 = fx("healthy")
    d2["facts"]["github"] = {"ok": False, "error": "rate limited", "open_pr_count": 1,
                             "open_prs": [{"number": 1, "merge_state_status": "CLEAN",
                                           "checks_green": True, "auto_armed": True,
                                           "draft": False, "probed": True}]}
    cfg2 = m.cfg_from_dict(d2["config"])
    v2 = [x for x in m.evaluate(d2["facts"], cfg2) if x.name == "landers"][0]
    assert (v2.status, v2.variant) == (m.INCONCLUSIVE, "GH_UNREADABLE"), (v2.status, v2.variant)

    # …and an ABSENT `ok` with a perfectly good population still abstains: allow-list polarity, so a
    # payload that never stated the surface was read is not a read. (`is not False` would grade it —
    # which is the defect this pins.)
    d3 = fx("healthy")
    d3["facts"]["github"] = {"open_pr_count": 1,
                             "open_prs": [{"number": 1, "merge_state_status": "CLEAN",
                                           "checks_green": True, "auto_armed": True,
                                           "draft": False, "probed": True}]}
    cfg3 = m.cfg_from_dict(d3["config"])
    v3 = [x for x in m.evaluate(d3["facts"], cfg3) if x.name == "landers"][0]
    assert (v3.status, v3.variant) == (m.INCONCLUSIVE, "GH_UNREADABLE"), (v3.status, v3.variant)


@test
def test_an_unrecognised_or_timed_out_send_is_AMBIGUOUS_not_refused():
    """safe-send.sh exits 5 for THREE states and a killed/timed-out send leaves the caller with no
    state at all, while the text may already be in the composer. Only a message that positively says
    nothing was consumed may be retried on the next poll; everything else stacks a second brief."""
    m = load()
    assert m.classify_send(0, "") == "delivered"
    assert m.classify_send(3, "REFUSED (lane busy): Nothing consumed") == "refused"
    assert m.classify_send(5, "FAILED-TO-START: Nothing was written; safe to retry") == "refused"
    assert m.classify_send(2, "usage: safe-send.sh <ws> <label> <file>") == "refused"
    # the ambiguous ones
    assert m.classify_send(1, "") == "ambiguous"
    assert m.classify_send(4, "sent, not consumed") == "ambiguous"
    assert m.classify_send(5, "UNKNOWN [$LABEL] $WS — cmux_dispatch rc=9; state NOT established.") == "ambiguous"
    assert m.classify_send(127, "TimeoutExpired: Command timed out after 300 seconds") == "ambiguous"
    assert m.classify_send(9, "") == "ambiguous"       # an rc nobody documented


@test
def test_the_sent_message_carries_the_respawn_evidence():
    """The documented wiring is launchd, where stdout is a log nobody reads: the MESSAGE is the only
    channel. The extras used to be composed AFTER the send, so `RESPAWN TOOK`/`DID NOT TAKE` reached
    only the report and the NOT-DELIVERED dump printed a different message from the one attempted."""
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-respawn-msg-")
    try:
        facts = os.path.join(tmp, "facts.json")
        d = fx("controller-absent")
        with open(facts, "w") as fh:
            json.dump(d, fh)
        cap = os.path.join(tmp, "cap")
        rc, out, err = run_cli(["--live", "--facts", facts, "--capture-dir", cap,
                                "--state", os.path.join(tmp, "s.json"),
                                # an explicit ws keeps the suite off `cmux workspace list` (the suite
                                # must be deterministic on a box with no cmux), and --dry-run reports
                                # the RESPAWN plan without running launchctl.
                                "--controller-ws", "00000000-0000-0000-0000-0000000000c1",
                                "--dry-run"])
        assert rc == 1, (rc, err[-400:])
        text = "".join(open(os.path.join(cap, f)).read() for f in os.listdir(cap)
                       if f.endswith(".txt"))
        assert "RESPAWN" in text, text[:600]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_a_lane_busy_REFUSAL_is_retried_not_suppressed():
    """safe-send.sh's COMMONEST refusal is the lane-guard's rc 3, whose message says "Not consumable"
    — never "Nothing consumed". A phrase list alone read it as AMBIGUOUS, so a controller busy
    mid-turn (the steady state of a WORKING controller) got one attempt per failure shape and then
    permanent silence, while nothing had been consumed and a retry was free."""
    m = load()
    lane_guard = ("REFUSED [canary] C2C97E96 \u2014 lane busy: state Working (mid-turn)\n"
                  "         Not consumable. A message sent now would QUEUE unread, or the state is\n"
                  "         UNKNOWN (which is NOT idle).")
    assert m.classify_send(3, lane_guard) == "refused", m.classify_send(3, lane_guard)
    assert m.classify_send(2, "usage: safe-send.sh <ws> <label> <file>") == "refused"
    # …and an ambiguous result still is not retried
    assert m.classify_send(4, "sent, not consumed") == "ambiguous"
    # end to end: a refused send is NOT recorded as suppressed
    v = m.V("work_dispatched", m.FAIL, "NOT_DISPATCHED", "e")
    st = m.State(os.path.join(tempfile.mkdtemp(prefix="oc-ref-"), "s.json"), "local")
    assert m._send_rc_is_ambiguous(m.classify_send(3, lane_guard)) is False
    assert m._send_rc_is_ambiguous("AMBIGUOUS: rc=4") is True


@test
def test_a_respawn_is_proved_by_the_HEARTBEAT_when_the_log_is_slow():
    """orch-loop.sh writes `heartbeat` BEFORE its rate-limit call and its first header line, so at
    load 130 (the load at which a respawn is needed) a SUCCESSFUL respawn can exceed the 40s bound.
    Proof used to require the LOG only, so the run reported — and SENT — "DID NOT TAKE" for a fleet
    that was already back, and skipped the re-collect that would have shown it."""
    m = load()
    v = m.V("controller_cycling", m.FAIL, "CONTROLLER_ABSENT", "e")

    class HbOnly(object):
        remote = False
        box = "local"
        o_dir = "/O"

        def __init__(self):
            self.n = 0

        def snapshot_controller(self):
            self.n += 1
            return {"ok": True, "pids": ([{"pid": 77}] if self.n > 1 else [])}

        def log_stat(self):
            return {"exists": True, "mtime": 1000, "age_s": 30.0}     # the log never advances

        def read_file(self, path):
            return ("1001\n" if self.n > 1 else "1000\n"), None      # the heartbeat DOES

        def sh_argv(self, argv, timeout=None):
            return 0, ""

    rr = m.attempt_respawn(v, m.Cfg(), HbOnly(), dry_run=False, poll_deadline_s=5.0)
    assert rr["took"] is True, rr


@test
def test_the_absent_verdict_shows_what_the_census_REJECTED():
    """The census is scoped to this cell, so it can reject a leaked fixture or another cell's
    controller. Reporting only a count makes "no controller" indistinguishable from "nothing was
    there to see" — the tool holds the datum and must read it."""
    m = load()
    d = fx("controller-absent")
    d["facts"]["controller"] = {
        "ok": True, "pids": [],
        "scoped_to": ["/Users/me/orchestrator/orch-loop.sh"],
        "near_misses": [{"pid": 9915, "cmd": "bash /var/folders/x/T/fleet-inventory-test.a/O/orch-loop.sh"}],
    }
    cfg = m.cfg_from_dict(d["config"])
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "controller_cycling"][0]
    assert v.variant == "CONTROLLER_ABSENT", v.variant
    assert "scoped to:" in v.evidence and "/Users/me/orchestrator/orch-loop.sh" in v.evidence, v.evidence
    assert "rejected" in v.evidence and "9915" in v.evidence, v.evidence


@test
def test_an_unwritable_outbox_is_NOT_DELIVERED_not_a_crash():
    """The guarded `makedirs` covers a MISSING directory; an EXISTING one can still be read-only or
    full, which is exactly the regime the file names ("a full disk is exactly when headroom is
    FAILing"). An unguarded write there killed the run AFTER the verdicts, losing the message from
    every artifact."""
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-outbox-")
    try:
        outbox = os.path.join(tmp, "outbox")
        os.makedirs(outbox)
        os.chmod(outbox, 0o500)
        cfg = m.Cfg(state_path=os.path.join(tmp, "s.json"))
        script = m._safe_send_path()
        sh = m.Machine(None, timeout=5)
        delivered, detail = m.send_message("body\n", cfg, sh, dry_run=False, ws="WS-UUID")
        assert delivered is False, detail
        assert "NOT DELIVERED" in detail, detail
        assert script is not None        # the script exists; the failure is the write, not the lookup
    finally:
        os.chmod(os.path.join(tmp, "outbox"), 0o700)
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_an_unwritable_state_path_reports_and_does_not_crash_the_run():
    """A full disk is exactly when `headroom` is FAILing and the canary is most active. An unguarded
    `state.save()` crashed AFTER sending (so the JSON report never printed and the exit code imitated
    a FAIL), and an un-persisted delivery mark turns "one message per state change" into "one per
    poll"."""
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-badstate-")
    try:
        facts = os.path.join(tmp, "facts.json")
        d = fx("dispatch-refused")
        with open(facts, "w") as fh:
            json.dump(d, fh)
        # a FILE where a directory must be: `blocker/s.json` can never be written (ENOTDIR)
        blocker = os.path.join(tmp, "blocker")
        with open(blocker, "w") as fh:
            fh.write("not a directory\n")
        cap = os.path.join(tmp, "cap")
        # ⛔ --controller-ws + --dry-run for the same reason as `_live_facts_args`: without them this
        # test could discover a workspace via `cmux workspace list` and `launchctl kickstart` the REAL
        # controller of the machine running the suite.
        rc, out, err = run_cli(["--live", "--facts", facts, "--capture-dir", cap, "--json",
                                "--controller-ws", "00000000-0000-0000-0000-0000000000c1",
                                "--dry-run", "--state", os.path.join(blocker, "s.json")])
        assert "Traceback" not in err, err[-400:]
        assert rc == 1, (rc, err[-300:])
        j = json.loads(out)          # the report still prints: the run did not die after sending
        assert j["exit"] == 1, j["exit"]
        assert j["signal"].get("state_error"), sorted(j["signal"].keys())
            # …and the delivery is still reported, not lost
        assert len(j["signal"]["sent"]) == 1, j["signal"]["sent"]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_a_recovery_rearms_an_ambiguously_sent_alert():
    """A recovery must re-arm BOTH halves of the alert: an ambiguous marker suppresses the shape it
    was recorded for, so fail(ambiguous) -> recover -> fail identically would be silent forever."""
    m = load()
    v = m.V("work_dispatched", m.FAIL, "NOT_DISPATCHED", "e")
    st = m.State(os.path.join(tempfile.mkdtemp(prefix="oc-rearm-"), "s.json"), "local")
    st.mark_ambiguous(v.key, 1.0)
    st.clear("work_dispatched")           # the fleet recovered
    assert st.is_ambiguous(v.key) is False, "a recovery must clear the ambiguity marker"
    to_send, _ = m.plan_notifications([v], st, "local", "iso", 2.0)
    assert [x.key for x, _ in to_send] == [v.key], ("the repeat failure went silent", to_send)


@test
def test_a_log_that_cannot_be_stat_ed_is_unreadable_not_missing():
    """A failed read is not a claim about the world: EACCES/TCC (or a timed-out probe) graded as
    "the log does not exist" fires LOG_MISSING, and the LOG_UNREADABLE abstention is unreachable."""
    m = load()

    class M(object):
        remote = False
        box = "local"
        log_path = "/x/orch-loop.log"
        tail_lines = 10

        def __init__(self, exists):
            self.exists = exists

        def sh(self, cmd, timeout=None):
            if cmd.startswith("stat"):
                return 1, "stat: Permission denied"
            if cmd.startswith("tail"):
                return 1, "tail: Permission denied"
            if cmd.startswith("test -e"):
                return 0, ("YES" if self.exists else "NO")
            return 0, ""

    log, lines, err = m.Machine.read_log(M(True), "/x/orch-loop.log")
    assert log["exists"] is True and log["age_s"] is None, log
    log, lines, err = m.Machine.read_log(M(False), "/x/orch-loop.log")
    assert log["exists"] is False, log

    facts = fx("healthy")["facts"]
    facts["log"] = {"path": "/x/orch-loop.log", "exists": True, "age_s": None,
                    "error": "stat: Permission denied"}
    cfg = m.cfg_from_dict(fx("healthy")["config"])
    v = [x for x in m.evaluate(facts, cfg) if x.name == "controller_cycling"][0]
    assert (v.status, v.variant) == (m.INCONCLUSIVE, "LOG_UNREADABLE"), (v.status, v.variant)


@test
def test_workspace_discovery_refuses_a_never_dispatch_pane():
    """A supervisor pane that says NEVER DISPATCH consumes the message if it is idle, so the failure
    is recorded DELIVERED and suppressed forever while the actor who could fix it was never told."""
    m = load()

    class FakeSh(object):
        def __init__(self, out):
            self.out = out

        def sh(self, cmd, timeout=None):
            return 0, self.out

    sup = FakeSh("* C2C97E96-0CBC-4DFE-BC91-FEF44F09B5BD  ORCHESTRATOR (never dispatch here)  [selected]\n")
    ws, why = m.find_controller_workspace(sup)
    assert ws is None, ws
    assert "NEVER DISPATCH" in why, why
    good = FakeSh("  AAAA1111-2222-3333-4444-555566667777  controller cell-2\n")
    assert m.find_controller_workspace(good, wanted_name="controller") == (
        "AAAA1111-2222-3333-4444-555566667777", "matched 'controller cell-2'")
    down = FakeSh("")
    assert m.find_controller_workspace(down)[0] is None


@test
def test_notifier_speaks_when_the_variant_shape_changes_back():
    """One message per state CHANGE. A failure alternating between two non-PASS shapes
    (NOT_DISPATCHED -> NO_DISPATCH_GATED -> NOT_DISPATCHED) recorded one key per shape, so the
    return to the first shape matched an already-notified key and went SILENT for good."""
    m = load()
    tmp = tempfile.mkdtemp(prefix="oc-variant-")
    try:
        state = os.path.join(tmp, "state.json")
        caps = []
        for name in ("dispatch-refused", "dispatch-gated", "dispatch-refused"):
            cap = os.path.join(tmp, "cap-%d" % len(caps))
            rc, out, err = run_cli(_live_facts_args(tmp, name, state, cap))
            assert rc == 1, (name, rc, err[-400:])
            caps.append(read_capture(cap))
        assert [len(c) for c in caps] == [1, 1, 1], [list(c) for c in caps]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_static_mode_never_touches_the_network_or_the_box():
    """`--static` must be evaluable in CI: it takes fixtures only. Proven by running it with a PATH
    that cannot reach gh/cmux and requiring the same verdict set."""
    tmp = tempfile.mkdtemp(prefix="oc-static-")
    try:
        empty = os.path.join(tmp, "bin")
        os.makedirs(empty, exist_ok=True)
        rc, out, err = run_cli(["--static", "--fixtures-dir", FIXTURES, "--json"],
                               env={"PATH": empty, "OUTCOME_CANARY_GH": os.path.join(empty, "gh")})
        assert rc == 0, (rc, err[-800:])
        j = json.loads(out)
        assert j["mismatches"] == [], j["mismatches"]
        assert len(j["fixtures"]) >= 10, len(j["fixtures"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_static_mode_catches_a_broken_predicate():
    """The suite must be able to FAIL: a fixture whose declared expectation is wrong is a mismatch."""
    tmp = tempfile.mkdtemp(prefix="oc-static-bad-")
    try:
        d = fx("healthy")
        d["_expect"]["work_dispatched"] = "FAIL"
        bad = os.path.join(tmp, "bad.json")
        with open(bad, "w") as fh:
            json.dump(d, fh)
        rc, out, err = run_cli(["--static", "--fixture", bad, "--json"])
        assert rc == 1, (rc, out[-400:])
        j = json.loads(out)
        assert j["mismatches"] and j["mismatches"][0]["check"] == "work_dispatched", j["mismatches"]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def test_a_stale_dispatch_line_is_not_graded_fresh():
    """A dispatch from two days ago is NOT evidence that work is moving now. The freshness bound is
    the difference between "the fleet is dispatching" and "the fleet dispatched once, long ago"."""
    m = load()
    d = fx("healthy")
    d["facts"]["log_events"]["dispatch_ok"] = [
        {"raw": "[dispatch] load=40 lanes=2 -> 4601 4602", "issues": [4601, 4602],
         "issue_count": 2, "age_s": 172800}]
    cfg = m.cfg_from_dict(d["config"])
    v = [x for x in m.evaluate(d["facts"], cfg) if x.name == "work_dispatched"][0]
    assert v.status == m.FAIL, (v.status, v.variant, v.evidence)
    assert v.variant == "NO_DISPATCH", v.variant


@test
def test_source_never_contains_a_forbidden_launchctl_form():
    """⛔ `unload -w` / `load -w` write a PERSISTENT Disabled override; a bootstrap that then fails
    leaves the controller removed AND disabled, silently (measured 2026-10-17, #1975).

    The check is on QUOTED forms, because that is how a forbidden token would appear in executable
    code. The prose may (and does) name the forbidden phrases — a doc that cannot quote a defect
    cannot explain it — but no string literal may carry one.
    """
    with open(MODULE) as fh:
        src = fh.read()
    for bad in ('"unload"', "'unload'", '"pkill"', "'pkill'", '"-w"', "'-w'",
                '"load", "-w"'):
        assert bad not in src, "forbidden form in a string literal: %s" % bad
    # and the positive half: the plan must be a kickstart, then a bootstrap, and nothing else
    m = load()
    plan = m.respawn_plan("com.example.label", "501", "/tmp/x.plist")
    assert plan[0][:3] == ["launchctl", "kickstart", "-k"], plan
    assert plan[0][3] == "gui/501/com.example.label", plan
    assert plan[1][:3] == ["launchctl", "bootstrap", "gui/501"], plan
    assert plan[1][3].endswith("x.plist"), plan
    assert len(plan) == 2, plan


# ════════════════════════════════════════════════════════════════════════════════════════════════
# 3. Mutations — each defect this file exists to catch, reintroduced
# ════════════════════════════════════════════════════════════════════════════════════════════════

MUTATIONS = [
    # (label, old, new, paired test)
    # ── cycle-24 defects ──────────────────────────────────────────────────────────────────
    ("a failed tail is graded as an empty log",
     '        tail_ok = rc2 == 0',
     "        tail_ok = True",
     "test_a_FAILED_TAIL_is_a_MISSING_read_not_an_empty_log"),
    ("a superseded header pair is graded anyway",
     '    superseded = (tok["kind"] == "EMPTY" and tok_src == "state/queue-state" and stale is None)',
     "    superseded = False",
     "test_a_current_EMPTY_state_record_supersedes_the_headers_large_pool"),
    ("a legible but OLD non-empty read is green",
     '        return V("queue_readable", INCONCLUSIVE, "READABLE_STALE", _queue_frozen_txt(f, stale),',
     '        return V("queue_readable", PASS, "READABLE", _queue_frozen_txt(f, stale),',
     "test_a_LEGIBLE_BUT_OLD_non_empty_read_is_not_GREEN"),
    ("a full merge-ordered page is called complete",
     "                     merged_page_full=len(merged_in_window_rows) >= 100)",
     "                     merged_page_full=False)",
     "test_a_FULL_merge_ordered_page_is_disclosed"),
    ("a stale read still grades work as not-dispatched",
     '    stale = _graded_stale(f, c, _tok_src)\n    if stale is not None:\n        # "Nothing to dispatch" is the CORRECT outcome only on a CURRENT read, and "work existed and',
     '    stale = _graded_stale(f, c, _tok_src)\n    if stale is not None and (stale["age_s"] is None or pool_kind == "EMPTY" or backlog == 0):\n        # "Nothing to dispatch" is the CORRECT outcome only on a CURRENT read, and "work existed and',
     "test_a_STALE_read_cannot_grade_work_as_NOT_dispatched"),
    ("fleet activity ignores open PRs and fresh dispatches",
     "    if isinstance(gh_open, int) and not isinstance(gh_open, bool) and gh_open > 0:",
     "    if False:",
     "test_a_STALE_header_cannot_manufacture_work_in_hand"),
    # ── cycle-23 defects ──────────────────────────────────────────────────────────────────
    ("the merge-ordered window bound moves a window into the future",
     "        now - cfg.pr_window_s, datetime.timezone.utc).strftime(\"%Y-%m-%d\")",
     "        now + cfg.pr_window_s, datetime.timezone.utc).strftime(\"%Y-%m-%d\")",
     "test_the_GRAPHQL_collector_reads_the_CLOSED_page_AND_a_MERGE_ordered_page"),
    ("the merge surface never reaches the report",
     '    merge = gh.get("merged_surface") or gh.get("fallback_note")',
     "    merge = None",
     "test_the_report_says_WHICH_READ_produced_the_merge_count"),
    ("an EMPTY backlog is paired with a pool from another refresh",
     '    pair = parse_queue_token(hdr.get("queue_token") or "")',
     '    pair = tok',
     "test_an_EMPTY_backlog_is_judged_against_the_pool_from_ITS_OWN_header"),
    ("fleet activity attributes the header's backlog to a newer state record",
     '    if _src == "state/queue-state" and kind == "EMPTY":',
     "    if False:",
     "test_an_EMPTY_state_record_supersedes_an_older_header_backlog"),
    ("pr_merged FAILs while its own activity input is unread",
     "    if busy is None:\n"
     '        # \u26d4 HOISTED ABOVE THE `open_n > 0` ARM.',
     "    if False:\n"
     '        # \u26d4 HOISTED ABOVE THE `open_n > 0` ARM.',
     "test_pr_merged_abstains_when_the_activity_input_is_unread"),
    # ── cycle-22 defects ──────────────────────────────────────────────────────────────────
    ("an unparseable header is graded as a mid-cycle wedge",
     "    if not cycles and unparsed:",
     "    if False:",
     "test_an_UNPARSEABLE_header_is_NOT_a_mid_cycle_wedge"),
    ("a bool headroom number is divided as a number",
     "    if disk.get(\"ok\") and (not isinstance(disk.get(\"avail_bytes\"), (int, float))\n"
     "                          or isinstance(disk.get(\"avail_bytes\"), bool)):",
     "    if disk.get(\"ok\") and not isinstance(disk.get(\"avail_bytes\"), (int, float)):",
     "test_a_BOOL_headroom_number_is_UNREAD_not_a_manufactured_OOM"),
    ("an unreadable pool token reads as benign idleness",
     "    if kind not in (\"EMPTY\", \"READ\", \"PARTIAL\") or (kind == \"READ\" and not "
     "isinstance(pool, int)):",
     "    if False:",
     "test_an_UNREADABLE_pool_is_not_reported_as_benign_idleness"),
    ("the report stops disclosing which cell was read",
     '            "o_dir": self.o_dir,',
     '',
     "test_the_report_discloses_WHICH_CELL_was_read"),
    # ── cycle-21 defects ──────────────────────────────────────────────────────────────────
    ("a full closed page is called truncated whatever its ordering",
     "                 merged_page_full=len(closed) >= 100 and not page_covers_window)",
     "                 merged_page_full=len(closed) >= 100)",
     "test_the_REST_collector_does_NOT_call_a_covering_page_TRUNCATED"),
    ("the REST collector stops passing the closed page as a created population",
     "    _fill_counts(out, open_raw, merged, cfg, now, also_created=closed,",
     "    _fill_counts(out, open_raw, merged, cfg, now,",
     "test_the_REST_collector_does_NOT_call_a_covering_page_TRUNCATED"),
    ("the GraphQL collector stops passing the closed page as a created population",
     "        _fill_counts(out, open_prs, merged_in_window_rows, cfg, now, also_created=closed,",
     "        _fill_counts(out, open_prs, merged_in_window_rows, cfg, now,",
     "test_the_GRAPHQL_collector_reads_the_CLOSED_page_AND_a_MERGE_ordered_page"),
    ("the merge-ordered read loses its window bound, so old merges count as new",
     '                       "--search", "merged:>=%s" % since, "--json", '
     '"number,mergedAt,createdAt"])',
     '                       "--json", "number,mergedAt,createdAt"])',
     "test_the_GRAPHQL_collector_reads_the_CLOSED_page_AND_a_MERGE_ordered_page"),
    ("an unread pane population is graded as zero daemons",
     '    if pane.get("ok") is True and not isinstance(pane.get("pids"), list):',
     "    if False:",
     "test_an_ABSENT_pane_population_is_not_a_measured_ZERO_daemons"),
    ("fleet activity trusts a header of any age",
     '    hdr = newest_with_age(events.get("headers"), window_s) if window_s is not None \\',
     '    hdr = newest(events.get("headers")) if False \\',
     "test_a_STALE_header_cannot_manufacture_work_in_hand"),
    ("a bool counts as a PR count",
     '    if not isinstance(n, int) or isinstance(n, bool):\n'
     '        return V("pr_created", INCONCLUSIVE, "GH_COUNT_UNREAD",',
     '    if not isinstance(n, int):\n'
     '        return V("pr_created", INCONCLUSIVE, "GH_COUNT_UNREAD",',
     "test_a_BOOL_is_not_a_count"),
    ("an absent auto_armed key is read as unarmed",
     '        if "auto_armed" not in pr:\n            unprobed.append(n)\n            continue',
     "        if False:\n            unprobed.append(n)\n            continue",
     "test_an_ABSENT_auto_armed_key_is_UNREAD_not_unarmed"),
    ("the report stops disclosing a verdict input",
     '            "window_s": self.window_s,',
     '',
     "test_the_report_DISCLOSES_every_input_that_changes_a_verdict"),
    # ── cycle-20 defects ──────────────────────────────────────────────────────────────────
    ("an `ok` gh surface with no created count is graded as a measured zero",
     '    if not isinstance(n, int) or isinstance(n, bool):\n'
     '        return V("pr_created", INCONCLUSIVE, "GH_COUNT_UNREAD",',
     '    if False:\n        return V("pr_created", INCONCLUSIVE, "GH_COUNT_UNREAD",',
     "test_an_ok_gh_surface_with_NO_COUNT_is_UNREAD_not_a_measured_zero"),
    ("an `ok` gh surface with no merged count is graded as a measured zero",
     '    if not isinstance(n, int) or isinstance(n, bool):\n'
     '        return V("pr_merged", INCONCLUSIVE, "GH_COUNT_UNREAD",',
     '    if False:\n        return V("pr_merged", INCONCLUSIVE, "GH_COUNT_UNREAD",',
     "test_an_ok_gh_surface_with_NO_COUNT_is_UNREAD_not_a_measured_zero"),
    ("a PR opened and closed unmerged drops out of the created population",
     "    for p in list(merged) + list(open_prs) + list(also_created or ()):",
     "    for p in list(merged) + list(open_prs):",
     "test_a_PR_opened_and_CLOSED_UNMERGED_still_counts_as_CREATED"),
    ("a row present in two populations is counted twice",
     "        if num is not None and num in seen:\n            continue",
     "        if False:\n            continue",
     "test_a_PR_opened_and_CLOSED_UNMERGED_still_counts_as_CREATED"),
    ("the report omits the input that decides STATE_FROZEN",
     '            "queue_stale_s": self.queue_stale_s,',
     '',
     "test_the_report_DISCLOSES_every_input_that_changes_a_verdict"),
    ("a live pid alone passes as a cycling controller",
     "    if log_age > win:", "    if False:",
     "test_controller_alive_with_frozen_log_is_fail_but_not_respawned"),
    ("refused dispatch attempts are forgiven",
     '    if refused:\n        return V("work_dispatched", FAIL, "NOT_DISPATCHED", evidence,',
     '    if False:\n        return V("work_dispatched", FAIL, "NOT_DISPATCHED", evidence,',
     "test_dispatch_refused_is_fail_not_dispatched"),
    ("an UNREADABLE pool passes as readable",
     '    if tok["kind"] == "UNREADABLE":', "    if False:",
     "test_queue_unreadable_is_fail"),
    ("a gh refusal passes as zero PRs",
     '    if gh.get("ok") is not True:\n        return V("pr_created", INCONCLUSIVE, "GH_UNREADABLE",',
     '    if False:\n        return V("pr_created", INCONCLUSIVE, "GH_UNREADABLE",',
     "test_gh_unreadable_is_inconclusive_never_green_never_zero"),
    ("the check-result rule becomes a DENY-list instead of an allow-list",
     '        if concl not in GREEN_CONCLUSIONS:',
     '        if concl == "FAILURE":',
     "test_rollup_polarity_unknown_and_null_conclusions_are_red"),
    ("the notifier speaks on every poll",
     "        if v.key in state.notified or state.is_ambiguous(v.key):",
     "        if False:",
     "test_notifier_deduplicates_on_unchanged_state"),
    ("a recovery does not re-arm the alert",
     "            state.clear(v.name)", "            pass",
     "test_a_recovery_rearms_the_alert"),
    ("respawn fires on any non-PASS check",
     '    if ctrl_v is not None and ctrl_v.variant in RESPAWN_TRIGGERS and not a.no_respawn:',
     '    if ctrl_v is not None and not a.no_respawn:',
     "test_respawn_is_planned_only_when_the_controller_is_genuinely_absent"),
    ("an INCONCLUSIVE run exits 0",
     '    if any(v.status == INCONCLUSIVE for v in verdicts):\n        return 2',
     "    if False:\n        return 2",
     "test_inconclusive_only_run_exits_2_not_0"),
    ("the census accepts a non-shell process holding the controller path",
     '        if not re.match(r"^(\\S*/)?(ba|z|da|k)?sh$", toks[0]):\n'
     '            near.append(row)\n            continue',
     "        pass",
     "test_the_census_requires_a_shell_invocation"),
    ("the census is not scoped to this cell's controller path",
     "        if paths and os.path.normpath(toks[1]) not in paths:", "        if False:",
     "test_the_census_is_scoped_to_THIS_cell_and_reports_what_it_rejected"),
    # ── cycle-13 defects ────────────────────────────────────────────────────────────
    ("an age-UNKNOWN non-empty pool read passes as READABLE",
     '    if stale is not None:\n        if stale["age_s"] is None:\n            return V("queue_readable", INCONCLUSIVE, "STATE_FROZEN", _queue_frozen_txt(f, stale),',
     '    if stale is not None and tok["kind"] == "EMPTY":\n        if stale["age_s"] is None:\n            return V("queue_readable", INCONCLUSIVE, "STATE_FROZEN", _queue_frozen_txt(f, stale),',
     "test_an_AGE_UNKNOWN_pool_read_is_not_READABLE"),
    ("a moving log counts as a cycling controller",
     "    if not cycles:",
     "    if False:",
     "test_a_MOVING_log_is_not_a_CYCLING_controller"),
    ("a partial --only run exits 0 with seven outcomes unprobed",
     "    if not_evaluated:\n        # ⛔ A CHECK THAT WAS NEVER EVALUATED IS NOT A PASS.",
     "    if False:\n        # ⛔ A CHECK THAT WAS NEVER EVALUATED IS NOT A PASS.",
     "test_a_PARTIAL_run_cannot_exit_0"),
    ("a usage error exits with the INCONCLUSIVE code",
     "        raise SystemExit(3)",
     "        raise SystemExit(2)",
     "test_a_usage_error_is_exit_3_not_the_inconclusive_code"),
    ("the pr_created evidence crosses its own labels",
     '          % (win / 3600.0, n, gh.get("open_pr_count"), gh.get("prs_merged_in_window"),',
     '          % (win / 3600.0, n, gh.get("prs_merged_in_window"), gh.get("open_pr_count"),',
     "test_the_pr_created_evidence_names_the_counts_it_prints"),
    # ⛔ THE MUTANT MUST EXPRESS THE DEFECT, NOT RAISE. Turning the guard off outright made `len()`
    # raise on a dict payload, so the RED came from the crash guard's PREDICATE_ERROR rather than
    # from "an unreadable payload was graded". Coercing to `[]` first reproduces what the check
    # actually did historically: an unread payload read as an EMPTY population.
    ("a payload with no open-PR rows is graded as zero PRs",
     "    if not isinstance(prs, list):",
     "    if not isinstance(prs, list):\n        prs = []\n    if False:",
     "test_a_payload_that_is_NOT_a_population_is_not_graded"),
    ("a payload whose count contradicts its rows is graded anyway",
     '    if not isinstance(gh.get("open_pr_count"), int) or gh["open_pr_count"] != len(prs):',
     "    if False:",
     "test_a_payload_that_is_NOT_a_population_is_not_graded"),
    ("a PR skipped for a known reason is dropped without being counted",
     '            skipped.append("%s:%s" % (pr.get("number"), mss))',
     '            pass',
     "test_a_PR_skipped_for_a_KNOWN_reason_is_COUNTED_and_PRINTED"),
    ("an unrecognised review decision silently removes a graded PR from the population",
     '            if str(rd).upper() in KNOWN_NON_MERGEABLE_REVIEWS:',
     '            if True:',
     "test_a_review_decision_that_is_NOT_recognised_is_UNPROBED_not_dropped"),
    # ── cycle-12 defects ────────────────────────────────────────────────────────────
    ("the rollup is grouped on the app, which the LIVE surface does not emit, so workflows collapse",
     '    wf = str(chk.get("workflowName") or "")',
     '    wf = ""',
     "test_the_rollup_is_graded_on_the_shape_the_LIVE_surface_actually_emits"),
    ("the rollup ranks attempts by list position instead of by timestamp",
     '        if e is not None and e > ts:\n            ts = e\n    return (0, 0.0, ts, pos)',
     '        if e is not None and e > ts:\n            ts = e\n    return (0, 0.0, 0.0, pos)',
     "test_the_rollup_is_graded_on_the_shape_the_LIVE_surface_actually_emits"),
    ("an attempt in flight is graded on the previous attempt's verdict",
     "        if any(_in_flight(chk) for _r, chk in entries):",
     "        if False:",
     "test_the_rollup_is_graded_on_the_shape_the_LIVE_surface_actually_emits"),
    ("an absent `probed` key reads as probed, so an unread PR is graded",
     '        if (pr.get("probed") is not True or green is None',
     '        if (pr.get("probed", True) is not True or green is None',
     "test_a_PR_row_that_cannot_be_GRADED_is_UNPROBED_not_silent"),
    ("an unrecognised mergeability state is skipped instead of abstaining",
     '                or (mss not in MERGEABLE_STATES and mss not in KNOWN_NON_MERGEABLE)):',
     '                or (mss not in MERGEABLE_STATES and mss in KNOWN_NON_MERGEABLE)):',
     "test_a_PR_row_that_cannot_be_GRADED_is_UNPROBED_not_silent"),
    ("a future-dated queue-state is clamped to the freshest possible reading",
     '        qs["age_s"] = _age_of(now, int(m.group(1))) if m else None',
     '        qs["age_s"] = max(0.0, now - int(m.group(1))) if m else None',
     "test_a_FUTURE_dated_queue_state_or_heartbeat_is_UNKNOWN_not_fresh"),
    ("a fixture may assert a SUBSET of the checks and still report success",
     "            gap = [n for n in CHECK_ORDER if n not in expect]",
     "            gap = []",
     "test_static_refuses_a_PARTIAL_expectation_and_a_MISSING_fixture"),
    ("a deleted outcome-critical fixture is not noticed",
     "            for name in missing_fixtures(paths):",
     "            for name in []:",
     "test_static_refuses_a_PARTIAL_expectation_and_a_MISSING_fixture"),
    # ── cycle-11 defects ────────────────────────────────────────────────────────────
    ("an unread check surface is graded RED, so a green unarmed PR drops out of the population",
     "    if not rollup:",
     "    if not rollup:\n        return False\n    if False:",
     "test_a_PR_with_NO_check_surface_is_UNPROBED_not_dropped_from_the_lander_population"),
    ("the pane census counts any process whose command line MENTIONS the daemon",
     '        is_daemon = (base0 == name\n'
     '                     or (len(toks) > 1 and os.path.basename(toks[1]) == name',
     '        is_daemon = (name in cmd or base0 == name\n'
     '                     or (len(toks) > 1 and os.path.basename(toks[1]) == name',
     "test_a_process_that_MENTIONS_the_daemon_is_not_the_daemon"),
    ("an empty gh response reads as zero PRs instead of a failed read",
     '    if not (txt or "").strip():\n        return None\n    try:\n        d = json.loads(txt)\n'
     '        return d if isinstance(d, list) else None',
     '    try:\n        d = json.loads(txt or "[]")\n'
     '        return d if isinstance(d, list) else None',
     "test_an_EMPTY_gh_response_is_a_failed_read_not_zero_PRs"),
    ("a truncated check-run page is graded as a green rollup",
     '                if isinstance(total, int) and total > len(runs["check_runs"]):',
     '                if False:',
     "test_a_TRUNCATED_check_run_page_is_not_a_green_rollup"),
    ("the header timezone token is dropped and the reading assumes local time",
     "        off = tz_offset_s(gd.get(\"tz\"))\n        if off is not None:\n"
     "            return calendar.timegm(struct) - off",
     "        off = None\n        if off is not None:\n"
     "            return calendar.timegm(struct) - off",
     "test_the_header_timezone_is_USED_so_a_remote_cell_is_not_graded_in_local_time"),
    ("a dry run persists the default notification state",
     '        if not self.persist:\n            return False          # a preview: the state was '
     'READ, never WRITTEN',
     "        if False:\n            return False",
     "test_a_dry_run_does_NOT_persist_the_default_notification_state"),
    ("a --box run grades a remote cell against THIS machine's repo plist",
     "    elif a.box:",
     "    elif False:",
     "test_a_box_run_does_not_grade_against_THIS_machines_repo"),
    ("an unparseable header is reported as a log that contains no header",
     '                    if unparsed else ""),',
     '                    if False else ""),',
     "test_an_UNPARSEABLE_header_is_reported_as_unparseable_not_as_absent"),
    ("the idle-empty-pool PASS is reported as a DISPATCH",
     '        return V("work_dispatched", PASS, "IDLE_EMPTY_POOL", evidence,',
     '        return V("work_dispatched", PASS, "DISPATCHED", evidence,',
     "test_a_genuinely_EMPTY_pool_is_IDLE_and_the_report_SAYS_idle"),
    ("a check excluded by --only is graded as a mismatch, so --static --only can never pass",
     "                if only and name in PREDICATES:",
     "                if False:",
     "test_a_fixture_expectation_naming_an_unknown_check_is_a_mismatch"),
    # ── cycle-10 defects ────────────────────────────────────────────────────────────
    ("a re-run attempt is judged by its OLDEST entry, so a flaky job that re-ran green reads red",
     "        _rank, chk = max(entries, key=lambda e: e[0])",
     "        _rank, chk = min(entries, key=lambda e: e[0])",
     "test_a_flaky_re_run_reads_GREEN_rather_than_red"),
    ("an armed decision in the log is a lander forever, however old or unaged",
     '    armed_log = _in_window(events.get("armed"), c.pr_window_s)',
     '    armed_log = _decisions(events.get("armed"))',
     "test_an_ANCIENT_or_UNAGED_rail_decision_is_not_a_lander"),
    ("a rail decision in the log is a lander forever, however old or unaged",
     '    railed_log = _in_window(events.get("railed"), c.pr_window_s)',
     '    railed_log = _decisions(events.get("railed"))',
     "test_an_ANCIENT_or_UNAGED_rail_decision_is_not_a_lander"),
    ("the REST probe bound is not a config field, so the bound an operator sets does nothing",
     '        "pool_threshold",\n        "rest_probe_max",',
     '        "pool_threshold",',
     "test_the_REST_probe_bound_is_a_REAL_knob_not_an_internal_constant"),
    # ── cycle-8 defect ──────────────────────────────────────────────────────────
    ("a zero staleness limit is treated as unset, so \"no tolerance\" is silently made lenient",
     "    return 5400.0 if limit is None else float(limit)",
     "    return limit or 5400.0",
     "test_a_ZERO_staleness_limit_means_NO_tolerance_not_unset"),
    # ── cycle-7 defects ──────────────────────────────────────────────────────────────
    ("an EMPTY read with NO age is graded as a current read",
     '    if age is None:\n'
     '        # an unaged reading cannot support ANY claim',
     '    if age is None:\n        return None\n'
     '    if False:\n'
     '        # an unaged reading cannot support ANY claim',
     "test_an_EMPTY_read_with_NO_age_is_not_a_current_read"),
    ("the staleness limit is not a config field, so the flag and fixture config do nothing",
     '    FIELDS = (\n        "window_s",\n        "pr_window_s",\n        "queue_stale_s",',
     '    FIELDS = (\n        "window_s",\n        "pr_window_s",',
     "test_the_staleness_limit_is_CONFIGURABLE_and_actually_applies"),
    # ── cycle-6 defects ──────────────────────────────────────────────────────────────
    ("the age of the pool read is parsed and never read, so a frozen read passes as current",
     "    if age <= limit:\n        return None",
     "    if True:\n        return None",
     "test_a_FROZEN_pool_read_is_not_a_current_one"),
    ("a frozen read still lets work_dispatched bless 'nothing to dispatch'",
     '        return V("work_dispatched", INCONCLUSIVE, "STATE_FROZEN", _queue_frozen_txt(f, stale),',
     '        return V("work_dispatched", PASS, "IDLE_EMPTY_POOL", _queue_frozen_txt(f, stale),',
     "test_a_FROZEN_pool_read_is_not_a_current_one"),
    ("a future-dated log mtime is clamped to '0s ago'",
     '                 "age_s": (None if skew < -CLOCK_SKEW_TOLERANCE_S else max(0.0, skew)),',
     '                 "age_s": max(0.0, skew),',
     "test_a_future_dated_log_mtime_is_UNKNOWN_not_the_freshest_possible"),
    ("an empty _expect set asserts nothing and reports success",
     '            mism.append((path, "(fixture)", ">=1 expectation", "NO_EXPECT", None))',
     "            pass",
     "test_a_fixture_with_no_expect_asserts_nothing_and_says_so"),
    ("a truncated open-PR page is treated as the whole population",
     '    if gh.get("page_full"):', "    if False:",
     "test_a_truncated_open_PR_population_is_not_a_population"),
    # ── cycle-5 defects ──────────────────────────────────────────────────────────────
    ("REST's lowercase mergeability state is not normalised, so landers grades nothing",
     '        row["merge_state_status"] = (det.get("mergeable_state") or "").strip().upper()',
     '        row["merge_state_status"] = det.get("mergeable_state")',
     "test_landers_grades_REST_shaped_rows"),
    ("an unknown mergeability is treated as graded rather than unprobed",
     '        row["probed"] = (row["checks_green"] is not None\n'
     '                         and row["merge_state_status"] not in MERGEABILITY_UNKNOWN)',
     '        row["probed"] = row["checks_green"] is not None',
     "test_landers_grades_REST_shaped_rows"),
    ("an EMPTY pool with no backlog field is blessed as genuinely empty",
     '    if pool_kind == "EMPTY" and backlog is None:\n'
     '        return V("work_dispatched", INCONCLUSIVE, "HEADER_INCOMPLETE",',
     '    if False:\n        return V("work_dispatched", INCONCLUSIVE, "HEADER_INCOMPLETE",',
     "test_an_EMPTY_pool_without_a_backlog_field_is_not_graded_idle"),
    ("a fixture _expect naming a check that does not exist asserts nothing",
     '                mism.append((path, name, want, "UNKNOWN_CHECK" if name not in PREDICATES',
     '                continue\n                mism.append((path, name, want, "UNKNOWN_CHECK" if name not in PREDICATES',
     "test_a_fixture_expectation_naming_an_unknown_check_is_a_mismatch"),
    # ── cycle-4 defects ──────────────────────────────────────────────────────────────
    ("the refusal decision ignores the exit code, so a lane-busy refusal goes silent",
     '    if rc in (2, 3):\n        return "refused"', "    if False:\n        return \"refused\"",
     "test_a_lane_busy_REFUSAL_is_retried_not_suppressed"),
    ("a started controller is proved only by the log, never by the heartbeat",
     "        advanced = log_advanced or hb_advanced", "        advanced = log_advanced",
     "test_a_respawn_is_proved_by_the_HEARTBEAT_when_the_log_is_slow"),
    ("the rejected processes are collected and never shown",
     '                 "%s\\n"\n                 "launchd %s: %s\\n"\n'
     '                 "%s\\n"\n                 "%s\\n"\n'
     '                 "%s" % (_near_txt(ctrl) or "scoped to: (not configured)",',
     '                 "launchd %s: %s\\n"\n                 "%s\\n"\n'
     '                 "%s\\n"\n                 "%s" % (',
     "test_the_absent_verdict_shows_what_the_census_REJECTED"),
    ("an unwritable outbox crashes the run",
     '    try:\n        with open(path, "w") as fh:\n            fh.write(msg)\n'
     '    except Exception as exc:',
     '    if True:\n        with open(path, "w") as fh:\n            fh.write(msg)',
     "test_an_unwritable_outbox_is_NOT_DELIVERED_not_a_crash"),
    # ── cycle-3 defects ──────────────────────────────────────────────────────────────
    ("unread PRs are a footnote once one probed PR is armed",
     '    if unprobed:\n        return V("landers", INCONCLUSIVE, "PARTIAL_POPULATION", evidence,',
     '    if False:\n        return V("landers", INCONCLUSIVE, "PARTIAL_POPULATION", evidence,',
     "test_landers_never_reports_green_over_PR_it_did_not_read"),
    ("a MISSING github surface reads as a successful read",
     'def check_landers(f, c):\n    gh = f.get("github") or {}\n    if gh.get("ok") is not True:',
     'def check_landers(f, c):\n    gh = f.get("github") or {}\n    if gh.get("ok") is not False:',
     "test_a_MISSING_github_surface_is_not_a_successful_read"),
    ("an unrecognised send result is treated as a free retry",
     '    return "ambiguous"          # unknown rc / timeout / silence: assume the bytes may have landed',
     '    return "refused"',
     "test_an_unrecognised_or_timed_out_send_is_AMBIGUOUS_not_refused"),
    ("the respawn evidence is composed after the send",
     '            body = compose_message(v, verdicts, cfg.box, obs_iso, extra_lines=extra)\n'
     '            delivered, detail = (capture_message(body, a.capture_dir, v)',
     '            body = compose_message(v, verdicts, cfg.box, obs_iso, extra_lines=extra)\n'
     '            delivered, detail = (capture_message(_msg, a.capture_dir, v)',
     "test_the_sent_message_carries_the_respawn_evidence"),
    ("an unwritable state path crashes the run",
     '        try:\n            state.save()\n        except Exception as exc:\n'
     '            reported["state_error"] = "%s: %s" % (type(exc).__name__, exc)',
     '        state.save()',
     "test_an_unwritable_state_path_reports_and_does_not_crash_the_run"),
    # ── cycle-2 defects ──────────────────────────────────────────────────────────────────────
    ("the respawn acts on an unreadable table at the moment of action",
     '    if before.get("ok") is False:', "    if False:",
     "test_respawn_abstains_when_a_controller_appeared_after_the_facts"),
    ("a recent log proves a respawn took, without advancing",
     "        advanced = log_advanced or hb_advanced",
     '        advanced = (after.get("log_age_s") is not None and after["log_age_s"] < 120)',
     "test_respawn_requires_the_log_to_ADVANCE_not_merely_be_recent"),
    ("the kernel default oom_score_adj 0 counts as protection",
     "    protected = [a for a in known if a < 0]", "    protected = [a for a in known if a <= 0]",
     "test_a_zero_oom_score_adj_is_not_protection"),
    ("a future-dated event is graded fresh",
     "    return None if age < -CLOCK_SKEW_TOLERANCE_S else age", "    return age",
     "test_a_future_dated_event_is_unknown_never_fresh"),
    ("a capture run writes the DEFAULT state file",
     "    if a.capture_dir and not a.state_path:", "    if False:",
     "test_capture_never_writes_the_default_state_path"),
    ("an ambiguous send is blind-retried every poll",
     "        if v.key in state.notified or state.is_ambiguous(v.key):",
     "        if v.key in state.notified:",
     "test_an_ambiguous_send_is_not_blind_retried_but_a_refusal_is"),
    ("a failed stat is reported as a missing log",
     "            rc3, present = self.sh(\"test -e %s && echo YES || echo NO\" % _q(path))\n"
     "            exists = (present.strip().endswith(\"YES\")) if rc3 == 0 else None",
     "            exists = False",
     "test_a_log_that_cannot_be_stat_ed_is_unreadable_not_missing"),
    ("the graded record borrows the age of the record it beat",
     "    if tok_src == \"state/queue-state\":\n        qs = f.get(\"queue_state\") or {}\n"
     "        age = qs.get(\"age_s\")",
     "    if False:\n        qs = f.get(\"queue_state\") or {}\n        age = qs.get(\"age_s\")",
     "test_the_GRADED_record_cannot_borrow_the_age_of_the_record_it_beat"),
    ("a start refuted by its own failure line still counts",
     "        live = [e for e in all_started if _is_this_batch(e)\n"
     "                and str(e.get(\"issue\")) not in failed_issues]",
     "        live = [e for e in all_started if _is_this_batch(e)]",
     "test_a_start_REFUTED_by_its_own_failure_line_is_not_a_live_lane"),
    ("the PASS prints the batch INTENT count as dispatched",
     "                    len(live), win, refused_txt, spawn_txt))",
     "                    ok.get(\"issue_count\") or 0, win, refused_txt, spawn_txt))",
     "test_a_start_REFUTED_by_its_own_failure_line_is_not_a_live_lane"),
    ("two statuses share one variant name (the notifier silences the worse)",
     "        return V(\"pane_daemon\", INCONCLUSIVE, \"PROTECTION_PARTIAL_UNREAD\",",
     "        return V(\"pane_daemon\", INCONCLUSIVE, \"PROTECTION_PARTIAL\",",
     "test_a_variant_name_carries_ONE_status_or_the_notifier_silences_the_worse_one"),
    ("a TORN (empty) queue record counts as a successful read",
     "        qs[\"ok\"] = False\n        qs[\"raw\"] = None\n"
     "        qs[\"error\"] = \"empty state/queue-state record (torn write)\"",
     "        qs[\"ok\"] = True\n        qs[\"raw\"] = None",
     "test_a_TORN_queue_record_is_a_failed_read_not_a_missing_key"),
    ("an ABSENT queue_state key grades green (deny-list polarity)",
     "    if qs_rec.get(\"ok\") is not True and tok_src == \"cycle header\":",
     "    if qs_rec.get(\"ok\") is False and tok_src == \"cycle header\":",
     "test_the_queue_checks_use_ALLOW_LIST_polarity_on_the_record"),
    ("work_dispatched's IDLE branch accepts an absent queue record",
     "            and (f.get(\"queue_state\") or {}).get(\"ok\") is True:",
     "            and (f.get(\"queue_state\") or {}).get(\"ok\") is not False:",
     "test_the_queue_checks_use_ALLOW_LIST_polarity_on_the_record"),
    ("an ok MEMORY read with no number reads as 0 MiB",
     "    if mem.get(\"ok\") and (not isinstance(mem.get(\"avail_mb\"), (int, float))\n"
     "                         or isinstance(mem.get(\"avail_mb\"), bool)):",
     "    if False:",
     "test_an_ok_MEMORY_read_with_no_number_is_UNREAD_not_zero_mib"),
    ("vm_stat sums the inactive/speculative fields without checking they were seen",
     "            \"if (!seen || ps == \\\"\\\" || free == \\\"\\\" || inact == \\\"\\\" || spec == "
     "\\\"\\\") \"",
     "            \"if (!seen || ps == \\\"\\\" || free == \\\"\\\") \"",
     "test_the_vm_stat_awk_refuses_a_NUMBER_when_any_SUMMED_field_is_missing"),
    ("a caller that cannot prove its page covers the window calls it complete",
     "        merged_page_full = True",
     "        merged_page_full = False",
     "test_the_merged_page_bound_models_the_SURFACE_that_produced_it"),
    ("fleet activity reads the one-refresh-old header token",
     "    _tok, _raw, _src = authoritative_queue_token(f, hdr)\n"
     "    pool = _tok.get(\"pool\")",
     "    _tok = parse_queue_token(hdr.get(\"queue_token\"))\n    _raw, _src = _tok.get(\"raw\"), "
     "\"cycle header\"\n    pool = _tok.get(\"pool\")",
     "test_fleet_activity_reads_the_SAME_queue_token_as_the_queue_checks"),
    ("a failed read of the queue record passes through the stale header",
     "    if qs_rec.get(\"ok\") is not True and tok_src == \"cycle header\":",
     "    if False:",
     "test_a_FAILED_READ_of_the_queue_record_does_not_pass_through_the_stale_header"),
    ("an UNPARSEABLE queue record is demoted to the header",
     "    if qs_tok is not None:",
     "    if qs_tok is not None and qs_tok[\"kind\"] != \"UNPARSEABLE\":",
     "test_a_FAILED_READ_of_the_queue_record_does_not_pass_through_the_stale_header"),
    ("the re-measure guard defaults an absent ok to a successful read",
     "    return {\"ok\": snap.get(\"ok\") is True,",
     "    return {\"ok\": snap.get(\"ok\", True),",
     "test_the_RE_MEASURE_guard_abstains_when_the_read_carries_no_ok"),
    ("the REST rollup groups two workflows by app+name",
     "        wf = _run_id_of(chk.get(\"details_url\") or chk.get(\"detailsUrl\") or \"\")",
     "        wf = \"\"",
     "test_the_REST_rollup_does_not_collapse_two_workflows_that_share_a_job_name"),
    ("an empty batch line lets any spawn vouch for it",
     "            if str(e.get(\"issue\")) not in batch_issues:",
     "            if batch_issues and str(e.get(\"issue\")) not in batch_issues:",
     "test_an_empty_batch_line_cannot_be_vouched_for_by_any_spawn"),
    ("an unread oom_score_adj counts as unprotected",
     "    if not known:",
     "    if False:",
     "test_an_UNREAD_oom_protection_value_is_UNEVALUABLE_not_unprotected"),
    ("an ok disk read with no number reads as 0 GiB",
     "    if disk.get(\"ok\") and (not isinstance(disk.get(\"avail_bytes\"), (int, float))\n"
     "                          or isinstance(disk.get(\"avail_bytes\"), bool)):",
     "    if False:",
     "test_an_ok_disk_read_with_no_number_is_UNREAD_not_zero_gib"),
    ("an unaged queue record forfeits its authority",
     "        if qs_age is None or hdr_age is None or qs_age < hdr_age:",
     "        if qs_age is not None and (hdr_age is None or qs_age < hdr_age):",
     "test_the_QUEUE_STATE_record_outranks_a_header_that_is_one_refresh_old"),
    ("the wired machine does not carry o_dir",
     "    m.o_dir = cfg.o_dir\n", "",
     "test_the_WIRED_machine_carries_o_dir_so_the_heartbeat_leg_works"),
    ("a foreign repo's rail decision counts as this repo's lander",
     "        elif n in railed_log and not repo_mismatch:",
     "        elif n in railed_log:",
     "test_a_lander_decision_from_ANOTHER_repo_does_not_vouch_for_this_repos_PR"),
    ("a foreign repo's armed decision counts as this repo's lander",
     "        elif n in armed_log and not repo_mismatch:",
     "        elif n in armed_log:",
     "test_a_lander_decision_from_ANOTHER_repo_does_not_vouch_for_this_repos_PR"),
    ("an empty process table is absence (it respawns)",
     "        if rc != 0 or not (out or \"\").strip():\n"
     "            return {\"ok\": False, \"pids\": [],",
     "        if rc != 0:\n"
     "            return {\"ok\": False, \"pids\": [],",
     "test_an_EMPTY_process_or_launchd_read_is_a_FAILED_READ_not_absence"),
    ("an absent controller.ok reads as an empty table",
     "    if ctrl.get(\"ok\") is not True:",
     "    if ctrl.get(\"ok\") is False:",
     "test_an_ABSENT_controller_ok_is_a_MISSING_read_not_an_empty_table"),
    ("a bad fixture path exits with the FAIL code",
     "            print(\"outcome-canary: %s\" % exc, file=sys.stderr)\n            return 3",
     "            print(\"outcome-canary: %s\" % exc, file=sys.stderr)\n            return 1",
     "test_a_bad_fixture_path_is_a_USAGE_error_not_the_FAIL_exit_code"),
    ("a truncated merged page reads as nothing merged",
     "    if gh.get(\"merged_page_full\") and not (isinstance(n, int) and not "
     "isinstance(n, bool) and n > 0):",
     "    if False:",
     "test_a_TRUNCATED_merged_page_does_not_read_as_nothing_merged"),
    ("a lane spawn from ANOTHER batch vouches for this one",
     "        live = [e for e in all_started if _is_this_batch(e)\n"
     "                and str(e.get(\"issue\")) not in failed_issues]",
     "        live = all_started",
     "test_a_lane_spawn_from_ANOTHER_batch_does_not_vouch_for_this_one"),
    ("a spawn that PRECEDES its batch line still counts",
     "            return e[\"age_s\"] <= ok_age + 2.0",
     "            return e[\"age_s\"] <= 9e9",
     "test_a_lane_spawn_from_ANOTHER_batch_does_not_vouch_for_this_one"),
    ("the queue verdict is read from the one-refresh-old header token",
     "    tok, raw_tok, tok_src = authoritative_queue_token(f, hdr)",
     "    tok, raw_tok, tok_src = parse_queue_token(hdr.get(\"queue_token\")), "
     "hdr.get(\"queue_token\"), \"cycle header\"",
     "test_the_QUEUE_STATE_record_outranks_a_header_that_is_one_refresh_old"),
    ("work_dispatched reads a different pool token than queue_readable",
     "    pool_kind = pool_kind if hdr is not None else None",
     "    pool_kind = parse_queue_token(hdr.get(\"queue_token\")).get(\"kind\")",
     "test_the_QUEUE_STATE_record_outranks_a_header_that_is_one_refresh_old"),
    ("an unreadable memory probe is reported as 0 MiB free",
     "            \"if (!seen || ps == \\\"\\\" || free == \\\"\\\" || inact == \\\"\\\" || spec == "
     "\\\"\\\") \"",
     "            \"\"",
     "test_an_UNPARSEABLE_memory_probe_is_INCONCLUSIVE_not_zero_free_mib"),
    ("an ABSENT open_pr_count counts as agreement",
     "    if not isinstance(gh.get(\"open_pr_count\"), int) or gh[\"open_pr_count\"] != len(prs):",
     "    if isinstance(gh.get(\"open_pr_count\"), int) and gh[\"open_pr_count\"] != len(prs):",
     "test_an_ABSENT_open_pr_count_is_a_missing_read_not_agreement"),
    ("a rollup AT the GraphQL page bound is graded anyway",
     "        if rollup_truncated(rollup):",
     "        if False:",
     "test_a_rollup_AT_the_graphql_page_bound_is_unprobed"),
    ("the dispatch INTENT line is graded as the dispatch outcome",
     "        all_started = events.get(\"lane_started\") or []",
     "        all_started = events.get(\"dispatch_ok\") or []",
     "test_a_dispatch_INTENT_is_not_a_dispatch"),
    ("an intent-only log PASSES instead of abstaining",
     "            return V(\"work_dispatched\", INCONCLUSIVE, \"DISPATCH_UNCONFIRMED\",",
     "            return V(\"work_dispatched\", PASS, \"DISPATCH_UNCONFIRMED\",",
     "test_a_dispatch_INTENT_is_not_a_dispatch"),
    ("a spawn failure is not parsed at all (the failure line is invisible)",
     "RE_LANE_FAILED = re.compile(\n"
     "    r\"^#(?P<issue>\\d+): (?P<reason>worktree add failed[^\\n]*|chain-\\d+ could NOT be "
     "started[^\\n]*)\\s*$\")",
     "RE_LANE_FAILED = re.compile(r\"^#(?P<issue>\\d+): LONG_MATCHES_NOTHING$\")",
     "test_the_spawn_line_shapes_the_harness_actually_prints_are_parsed"),
    ("the cycle-header window bound is dropped (any header ever seen counts)",
     "              if h.get(\"age_s\") is not None and h[\"age_s\"] <= win]",
     "              if h.get(\"age_s\") is not None]",
     "test_a_cycle_header_OLDER_than_the_window_is_not_a_cycle"),
    ("the queue token age loses its unit multiplier",
     "        mult = {\"s\": 1, \"m\": 60, \"h\": 3600}[a.group(\"unit\")]",
     "        mult = 1",
     "test_the_queue_token_AGE_is_read_with_ITS_OWN_multiplier"),
    ("a DRAFT PR is dropped with no line at all",
     '            skipped.append("%s:DRAFT" % (pr.get("number"),))\n            continue',
     "            continue",
     "test_a_DRAFT_PR_is_COUNTED_as_skipped_not_dropped_silently"),
    ("only the disk floor is graded",
     "        if mb < c.mem_floor_mb:\n"
     '            bad.append("memory %.0f MiB < %.0f MiB" % (mb, c.mem_floor_mb))',
     "        pass",
     "test_each_headroom_floor_is_graded_ON_ITS_OWN"),
    ("only the memory floor is graded",
     "        if gb < c.disk_floor_gb:\n"
     '            bad.append("disk %.1f GiB < %.1f GiB" % (gb, c.disk_floor_gb))',
     "        pass",
     "test_each_headroom_floor_is_graded_ON_ITS_OWN"),
    ("--static --only certifies the checks it never asserted",
     "        return 2 if only else 0",
     "        return 0",
     "test_a_fixture_expectation_naming_an_unknown_check_is_a_mismatch"),
    ("a recovery leaves the ambiguity marker behind (a repeat failure goes silent)",
     '        amb = self.data["boxes"][self.box].get("ambiguous") or {}\n'
     '        for k in list(amb):\n            if k.split("|")[0] == check:\n'
     '                del amb[k]',
     '        pass',
     "test_a_recovery_rearms_an_ambiguously_sent_alert"),
]


def run_suite(names=None, quiet=False):
    """Run the named (or all) tests against MODULE. Returns (passed, failed)."""
    passed = failed = 0
    for name, fn in TESTS:
        if names and name not in names:
            continue
        try:
            fn()
        except AssertionError as exc:
            failed += 1
            if not quiet:
                print("  ❌ %s\n       %s" % (name, exc))
            else:
                # ⛔ QUIET MODE STILL NAMES THE FAILURE AND ITS REASON, because the mutation harness
                # reads this line to tell a mutant that MIS-GRADES from one that CRASHES (the crash
                # guard turns the latter into INCONCLUSIVE/PREDICATE_ERROR, a red for the wrong
                # reason). One line, so `--mutations` stays readable.
                print("  ❌ %s: %s" % (name, str(exc)[:300]))
        except Exception as exc:
            failed += 1
            if not quiet:
                print("  ❌ %s\n       %s: %s" % (name, type(exc).__name__, exc))
            else:
                print("  ❌ %s: %s: %s" % (name, type(exc).__name__, str(exc)[:300]))
        else:
            passed += 1
            if not quiet:
                print("  ✅ %s" % name)
    return passed, failed


def run_mutations():
    """Each mutation must turn its PAIRED test RED. A mutation that survives is a suite failure."""
    ok = bad = 0
    with open(MODULE) as fh:
        src = fh.read()
    tmp = tempfile.mkdtemp(prefix="oc-mut-")
    try:
        for label, old, new, paired in MUTATIONS:
            assert src.count(old) == 1, "mutation anchor not unique (%d hits): %.60r" % (
                src.count(old), old)
            mutated = os.path.join(tmp, "outcome_canary_mut_%d.py" % len(os.listdir(tmp)))
            mutated_src = src.replace(old, new)
            # ⛔ A MUTANT THAT DOES NOT COMPILE IS NOT A CAUGHT DEFECT. `returncode != 0` scores an
            # unimportable module as RED, so a mutation could be "caught" by a SyntaxError no test
            # ever graded (measured: #57 replaced `try:` and left `except` dangling). Compile first
            # and fail the SUITE, never silently count it.
            try:
                compile(mutated_src, mutated, "exec")
            except SyntaxError as exc:
                bad += 1
                print("  ❌ INVALID MUTANT (not python, so its RED would be an import error, not a "
                      "caught defect) — %s\n       %s" % (label, exc))
                continue
            with open(mutated, "w") as fh:
                fh.write(mutated_src)
            env = dict(os.environ)
            env["OUTCOME_CANARY_MODULE"] = mutated
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            p = subprocess.run([sys.executable, os.path.abspath(__file__),
                                "--only", paired, "--quiet"],
                               capture_output=True, text=True, env=env, timeout=600)
            if p.returncode != 0:
                ok += 1
                # ⛔ A MUTANT THAT CRASHES IS NOT EVIDENCE THE PAIRED TEST DISCRIMINATES THE DEFECT.
                # `evaluate` turns a crashing predicate into INCONCLUSIVE/PREDICATE_ERROR, so a test
                # asserting "INCONCLUSIVE, but a different variant" goes red for the CRASH rather
                # than for the defect. Reported distinctly so a weak mutation cannot hide.
                crashed = "PREDICATE_ERROR" in (p.stdout or "") or "Traceback" in (p.stderr or "")
                print("  %s %s — %s\n       (paired: %s)%s"
                      % ("⚠️  RED (mutant CRASHED, not mis-graded)" if crashed else "✅ RED as required",
                         "" if crashed else "", label, paired,
                         "\n       the mutation must express the DEFECT, not make the code raise"
                         if crashed else ""))
            else:
                bad += 1
                print("  ❌ STILL GREEN — %s\n       %s did not catch it; the test is decoration"
                      % (label, paired))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return ok, bad


def main(argv=None):
    ap = argparse.ArgumentParser(description="outcome-canary acceptance suite")
    ap.add_argument("--only", default=None, help="comma-separated test names")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--mutations", action="store_true",
                    help="reintroduce each defect into a temp copy and require its test to go RED")
    a = ap.parse_args(argv)
    if a.list:
        for name, _ in TESTS:
            print(name)
        return 0
    names = [x.strip() for x in a.only.split(",")] if a.only else None
    if a.mutations:
        print("mutation evidence — every mutation must be caught by its paired test\n")
        ok, bad = run_mutations()
        print("\n%d caught · %d survived" % (ok, bad))
        return 1 if bad else 0
    print("outcome-canary suite — %s\nfixtures: %s\n" % (MODULE, FIXTURES))
    passed, failed = run_suite(names, quiet=a.quiet)
    print("\n%d passed · %d failed" % (passed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
