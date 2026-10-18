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
            "--controller-ws", "00000000-0000-0000-0000-0000000000c1", "--json"]


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
    assert got["work_dispatched"].status == m.INCONCLUSIVE, (
        got["work_dispatched"].status, got["work_dispatched"].variant)
    assert got["work_dispatched"].variant == "STATE_FROZEN", got["work_dispatched"].variant
    # a stale EMPTY read must not let the whole run report green
    assert m.exit_code(list(got.values())) in (1, 2), m.exit_code(list(got.values()))

    # …but a stale NON-EMPTY read still supports "readable, n candidates": dispatch may be flowing on
    # it, and failing that would cry wolf on a healthy box (measured here: READ(223)(57m) while two
    # issues had been dispatched 101s earlier).
    d3 = fx("healthy")
    d3["facts"]["log_events"]["headers"] = [{
        "raw": "=== Sun Oct 18 07:47:44 EST 2026 load=12 lanes=1 backlog=33 queue=READ(223)(6h) ===",
        "age_s": 60, "ts": 0, "backlog": 33, "queue_token": "READ(223)(6h)"}]
    d3["facts"]["queue_state"] = {"path": "q", "ok": True, "raw": "READ(223)", "age_s": 6 * 3600.0}
    cfg3 = m.cfg_from_dict(d3["config"])
    got3 = dict((v.name, v) for v in m.evaluate(d3["facts"], cfg3))
    assert got3["queue_readable"].status == m.PASS, (got3["queue_readable"].variant,
                                                     got3["queue_readable"].evidence)

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
        d["_expect"] = {"lnders": "FAIL"}
        bad = os.path.join(tmp, "bad.json")
        with open(bad, "w") as fh:
            json.dump(d, fh)
        rc, out, err = run_cli(["--static", "--fixture", bad, "--json"])
        assert rc == 1, (rc, out[-300:])
        j = json.loads(out)
        assert j["mismatches"] and j["mismatches"][0]["got"] == "UNKNOWN_CHECK", j["mismatches"]
        # and a check excluded by --only must not be silently counted as asserted
        d2 = fx("healthy")
        d2["_expect"] = {"landers": "PASS"}
        only = os.path.join(tmp, "only.json")
        with open(only, "w") as fh:
            json.dump(d2, fh)
        rc, out, err = run_cli(["--static", "--fixture", only,
                                "--only", "work_dispatched", "--json"])
        assert rc == 1, (rc, out[-300:])
        j = json.loads(out)
        assert any(x["got"] == "NOT_EVALUATED" for x in j["mismatches"]), j["mismatches"]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


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
                                "--state", os.path.join(tmp, "s.json")])
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
        rc, out, err = run_cli(["--live", "--facts", facts, "--capture-dir", cap, "--json",
                                "--state", os.path.join(blocker, "s.json")])
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
     '        if str(concl).upper() not in GREEN_CONCLUSIONS:',
     '        if str(concl).upper() == "FAILURE":',
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
    # ── cycle-6 defects ──────────────────────────────────────────────────────────────
    ("the age of the pool read is parsed and never read, so a frozen read passes as current",
     "    if age is None or age <= limit:\n        return None",
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
     '    if True:\n        with open(path, "w") as fh:\n            fh.write(msg)\n'
     '    except Exception as exc:',
     "test_an_unwritable_outbox_is_NOT_DELIVERED_not_a_crash"),
    # ── cycle-3 defects ──────────────────────────────────────────────────────────────
    ("unread PRs are a footnote once one probed PR is armed",
     '    if unprobed:\n        return V("landers", INCONCLUSIVE, "PARTIAL_POPULATION", evidence,',
     '    if False:\n        return V("landers", INCONCLUSIVE, "PARTIAL_POPULATION", evidence,',
     "test_landers_never_reports_green_over_PR_it_did_not_read"),
    ("a MISSING github surface reads as a successful read",
     'def check_landers(f, c):\n    gh = f.get("github") or {}\n    if gh.get("ok") is not True:',
     'def check_landers(f, c):\n    gh = f.get("github") or {}\n    if gh.get("ok") is False:',
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
        except Exception as exc:
            failed += 1
            if not quiet:
                print("  ❌ %s\n       %s: %s" % (name, type(exc).__name__, exc))
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
            with open(mutated, "w") as fh:
                fh.write(src.replace(old, new))
            env = dict(os.environ)
            env["OUTCOME_CANARY_MODULE"] = mutated
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            p = subprocess.run([sys.executable, os.path.abspath(__file__),
                                "--only", paired, "--quiet"],
                               capture_output=True, text=True, env=env, timeout=600)
            if p.returncode != 0:
                ok += 1
                print("  ✅ RED as required — %s\n       (paired: %s)" % (label, paired))
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
