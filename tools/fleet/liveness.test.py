#!/usr/bin/env python3
"""tools/fleet/liveness.test.py — the #1178 acceptance suite.

Fifty tests with seventy-three paired mutations: every mutation re-
introduces the defect its test exists to catch, so "the test fails without the
fix" is an EXECUTED claim rather than an asserted one. Two prior artifacts in
this repo claimed mutation evidence they did not have; this file makes the
evidence mechanical. Seven (#1254) pin the TURN-BOUNDARY rule:
``wedged`` requires positive evidence of an OPEN turn, so a turn-ended lane
is never a stall and a frozen lane with an unreadable boundary abstains. Two
more close cycle-1 review findings on that rule: a message carrying tool calls
is OPEN unless its stop reason discards them (on ``length`` pi fails those calls
and continues the turn, so it is OPEN), and a ``compaction`` as the last entry
abstains rather than letting the turn before it decide. T20 (#1272) closes the
other direction: `turn-ended` is an EXPLICIT terminal set, and a stopReason
outside it abstains on a call-free message (`turn-unknown:<value>`) instead of
defaulting to resting (a call-carrying message is decided by the call-carrying
rule first).

    python3 tools/fleet/liveness.test.py                # the 50 tests, green
    python3 tools/fleet/liveness.test.py --mutations     # each mutation, RED (68)

`--mutations` writes a mutated copy of the module (or of the identity library)
to a temp dir and runs the paired test against it in a subprocess — the real
file is never modified. A mutation whose paired test PASSES is reported as a
failure of the suite (a test that cannot catch its own defect is decoration).

Injected, never guessed:
  * LIVENESS_MODULE      — the module under test (default: ./liveness.py)
  * PI_PID_IDENTITY_LIB  — the probe CLI (default: ../../scripts/lib/pid-identity.sh)
"""

from __future__ import annotations

import contextlib
import dataclasses
import datetime
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_PATH = os.path.normpath(os.path.join(HERE, "liveness.py"))
LIB_PATH = os.path.normpath(os.path.join(HERE, "..", "..", "scripts", "lib", "pid-identity.sh"))

os.environ.setdefault("PI_PID_IDENTITY_LIB", LIB_PATH)


def _load_module():
    path = os.environ.get("LIVENESS_MODULE") or MODULE_PATH
    spec = importlib.util.spec_from_file_location("fleet_liveness_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    # Register BEFORE exec: dataclasses resolves string annotations through
    # sys.modules[cls.__module__] (a file-loaded module is otherwise absent).
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


liv = _load_module()

# ── the clock and the bounds, expressed once ─────────────────────────────
M = 60 * 1000
H = 3600 * 1000
NOW_S = 1_789_000_000
NOW_MS = NOW_S * 1000
PROBE_EPOCH = 1_760_000_000
PROBE_LSTART = "Thu Sep 18 14:40:00 2026"


# ── tiny test runner (the suite is a script, not a pytest module) ────────
TESTS = []


def test(name):
    def deco(fn):
        TESTS.append((name, fn))
        return fn
    return deco


class Failure(AssertionError):
    pass


def check(cond, msg):
    if not cond:
        raise Failure(msg)


def C(pid, observed, kind="tag", start=None):
    return liv.Candidate(pid=pid, observed=observed, kind=kind, start_seconds=start)


def _iso(ms):
    """pi's entry-level `timestamp`: ISO-8601 UTC, millisecond precision."""
    return datetime.datetime.fromtimestamp(ms / 1000.0, datetime.timezone.utc) \
        .strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (ms % 1000)


def ev(**kw):
    base = dict(sid="sid-1", now_ms=NOW_MS, jsonl_grew=False, jsonl_age_ms=H)
    base.update(kw)
    return liv.Evidence(**base)


# #1254 — the turn boundary. The exact entry shapes pi writes (measured over 426
# live session files), and the two Turn values the ladder distinguishes.
def entry(role, **msg):
    base = {"role": role}
    base.update(msg)
    return {"type": "message", "message": base}


def assistant_tooluse(*calls):
    return entry("assistant", stopReason="toolUse",
                 content=[{"type": "toolCall", "name": n, "id": i} for n, i in calls])


COMPLETE_TURN = liv.Turn(False, "turn-ended", "terminal stopReason=stop")
OPEN_TURN = liv.Turn(True, "turn-open:pending-tool-call", "unanswered bash(call_test)")


# ── the probe shim (a fake `ps` + `date`, mirroring the reaper's test shim) ──
PS_SHIM = """#!/usr/bin/env bash
[ "${1:-}" = "-axo" ] || exit 1
[ "@FAIL@" = "1" ] && exit 1
cat "@SOURCE@"
"""

DATE_SHIM = """#!/usr/bin/env bash
arg=""
for a in "$@"; do
    case "$a" in %*|+%s|-j|-f|-d) continue ;; esac
    arg="$a"
done
if [ "$arg" = "Sat Jan  1 00:00:00 2000" ]; then echo 946684800; exit 0; fi
hit="$(awk -F'\\t' -v k="$arg" '$1==k {print $2}' "@LOOKUP@" | head -1)"
[ -n "$hit" ] && { echo "$hit"; exit 0; }
exit 1
"""


def ps_row(pid, lstart=PROBE_LSTART, stat="S", cmd="/usr/local/bin/pi"):
    return "%d 1 %d ttys001 %s %s 1234 %s" % (pid, pid, lstart, stat, cmd)


@contextlib.contextmanager
def ps_env(rows, *, ps_fail=False, lookup=None):
    """Point PS_BIN/DATE_BIN at hermetic shims for the duration of the block."""
    d = tempfile.mkdtemp(prefix="liv-probe-")
    try:
        src = os.path.join(d, "ps-source")
        with open(src, "w", encoding="utf-8") as fh:
            fh.write("\n".join(rows) + ("\n" if rows else ""))
        ps = os.path.join(d, "ps")
        with open(ps, "w", encoding="utf-8") as fh:
            fh.write(PS_SHIM.replace("@FAIL@", "1" if ps_fail else "0").replace("@SOURCE@", src))
        os.chmod(ps, 0o755)
        look = os.path.join(d, "date.lookup")
        with open(look, "w", encoding="utf-8") as fh:
            for key, val in (lookup or {PROBE_LSTART: PROBE_EPOCH}).items():
                fh.write("%s\t%d\n" % (key, val))
        dt = os.path.join(d, "date")
        with open(dt, "w", encoding="utf-8") as fh:
            fh.write(DATE_SHIM.replace("@LOOKUP@", look))
        os.chmod(dt, 0o755)
        saved = {k: os.environ.get(k) for k in ("PS_BIN", "DATE_BIN")}
        os.environ["PS_BIN"] = ps
        os.environ["DATE_BIN"] = dt
        try:
            yield
        finally:
            for key, val in saved.items():
                if val is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = val
    finally:
        shutil.rmtree(d, ignore_errors=True)


@contextlib.contextmanager
def temp_store(payload):
    d = tempfile.mkdtemp(prefix="liv-store-")
    try:
        path = os.path.join(d, "pi-hook-sessions.json")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(payload if isinstance(payload, str) else json.dumps(payload))
        yield path, d
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ══════════════════════════════════════════════════════════════════════════
# T1 — pid reuse. The fence DEFEATS reuse: an unrelated process that inherited a
# dead session's pid is not its holder. (Spec §4.1 says "→ dead"; C1 says
# off-fence must ABSTAIN. This test implements C1 — the mandatory fix — and
# asserts "not a holder, never dead". See the report.)
# ══════════════════════════════════════════════════════════════════════════
@test("T1 pid-reuse: the fence defeats the reused pid (never a holder, never dead)")
def t1_pid_reuse():
    v = liv.evaluate(ev(candidates=[C(100, "off-fence", start=1000)]))
    check(v.state != "dead", "an off-fence (reused) pid must never witness dead; got %s/%s" % (v.state, v.reason))
    check(v.state == "unknown", "a reused pid is an identity uncertainty -> unknown; got %s" % v.state)
    check(v.reason == "off-fence" or "off-fence" in v.detail,
          "the evidence must name off-fence: reason=%s detail=%s" % (v.reason, v.detail))

    v2 = liv.evaluate(ev(candidates=[C(100, "holder", start=1000)], jsonl_age_ms=5 * M))
    check(v2.state == "running-quiet" and v2.holder_pid == 100,
          "the on-fence incarnation is the holder; got %s" % (v2,))

    live = os.getpid()
    with ps_env([ps_row(live)]):
        reused = liv.probe_pid(live, PROBE_EPOCH + 100)
        same = liv.probe_pid(live, PROBE_EPOCH + 3)
    check(reused.rc == 2 and reused.status == "off-fence",
          "a pid whose lstart is +100s off the record must be off-fence/exit 2; got rc=%s status=%s (%s)"
          % (reused.rc, reused.status, reused.detail))
    check(same.rc == 0 and same.status == "holder",
          "a pid within +3s of the record is the holder; got rc=%s status=%s" % (same.rc, same.status))


# ══════════════════════════════════════════════════════════════════════════
# T2 — the HEADLINE (C1). A live process whose recorded pidStartSeconds is
# off-fence (stale, wrong, or unparseable) must abstain, never die.
# ══════════════════════════════════════════════════════════════════════════
@test("T2 off-fence live holder -> unknown, never dead (C1)")
def t2_off_fence_abstains():
    v = liv.evaluate(ev(candidates=[C(100, "off-fence", start=1000)]))
    check(v.state == "unknown", "a live off-fence holder must be unknown; got %s/%s" % (v.state, v.reason))
    check(v.state != "dead", "off-fence must never witness dead (C1)")

    v2 = liv.evaluate(ev(candidates=[C(100, "unreadable", start=None)]))
    check(v2.state == "unknown" and v2.state != "dead",
          "an unusable record stamp must be unknown; got %s/%s" % (v2.state, v2.reason))

    v3 = liv.evaluate(ev(candidates=[C(100, "absent", start=1000), C(200, "off-fence", start=2000)]))
    check(v3.state == "unknown",
          "one off-fence candidate must block dead even with an absent sibling; got %s" % v3.state)

    check(liv.is_dead_evidence([]) is False, "the dead predicate must be non-vacuous")
    check(liv.is_dead_evidence([C(1, "off-fence")]) is False, "off-fence is not dead evidence")


# ══════════════════════════════════════════════════════════════════════════
# T3 — an unrecorded live writer (C2). A resumed session holds a STALE record
# (dead pid) while the live process carries no tag; its argv names the session.
# ══════════════════════════════════════════════════════════════════════════
@test("T3 stale record + untagged live writer -> not dead (argv candidate source, C2)")
def t3_argv_candidate_source():
    sessions = {"sid-1": {"pid": 100, "pidStartSeconds": 1000, "cwd": "/x"}}

    def probe_fn(pid, start, kind):
        return "holder" if kind == "argv" else "absent"

    cands = liv.collect_candidates("sid-1", sessions, [200], probe_fn)
    kinds = sorted(c.kind for c in cands)
    check(kinds == ["argv", "tag"],
          "the candidate set must UNION the store record and the argv claim; got %s" % kinds)
    v = liv.evaluate(ev(candidates=cands, jsonl_grew=False, jsonl_age_ms=5 * M))
    check(v.state == "running-quiet",
          "an unrecorded live writer must not be dead; got %s/%s" % (v.state, v.reason))
    check(v.holder_pid == 200, "the argv-claiming pid is the holder; got %s" % v.holder_pid)

    sessions2 = {"sid-1": {"pid": 100, "pidStartSeconds": 1000,
                           "priorProcessGenerations": [{"pid": 300, "startSeconds": 900}]}}

    def probe_fn2(pid, start, kind):
        return "holder" if pid == 300 else "absent"

    cands2 = liv.collect_candidates("sid-1", sessions2, [], probe_fn2)
    check(len(cands2) == 2, "prior generations must be candidates; got %s" % [c.pid for c in cands2])
    v2 = liv.evaluate(ev(candidates=cands2, jsonl_grew=False, jsonl_age_ms=5 * M))
    check(v2.state == "running-quiet" and v2.holder_pid == 300,
          "a live prior generation is a holder; got %s" % (v2,))

    with ps_env([ps_row(700, cmd="node /x/pi --session sid-1"), ps_row(701, cmd="node /x/pi")]):
        pids, ok = liv.argv_candidates("sid-1")
    check(ok and pids == [700],
          "argv-candidates must find exactly the --session pid; got ok=%s pids=%s" % (ok, pids))


# ══════════════════════════════════════════════════════════════════════════
# T4 — a failed `ps` read is UNKNOWN, never "absent" (C3).
# ══════════════════════════════════════════════════════════════════════════
@test("T4 unreadable ps -> unknown, never dead (C3)")
def t4_ps_unreadable():
    check(liv.observed_from_probe(2, "unknown") == "unreadable",
          "exit 2 must map to an abstention, not absence")
    check(liv.observed_from_probe(2, "off-fence") == "off-fence", "off-fence must survive the mapping")
    check(liv.observed_from_probe(1, "absent") == "absent", "exit 1 + absent is the dead witness")
    check(liv.observed_from_probe(1, "zombie") == "zombie", "exit 1 + zombie is the dead witness")
    check(liv.observed_from_probe(0, "holder") == "holder", "exit 0 is the holder")

    with ps_env([], ps_fail=True):
        res = liv.probe_pid(1000, 1000)
    check(res.rc == 2,
          "a failed ps read must be exit 2 (unknown), never 1 (absent); got rc=%s (%s)" % (res.rc, res.detail))
    observed = liv.observed_from_probe(res.rc, res.status)
    check(observed == "unreadable", "a failed read is unreadable; got %s" % observed)

    v = liv.evaluate(ev(candidates=[C(1000, observed)]))
    check(v.state != "dead", "a manufactured dead from a failed command is the C3 defect; got %s" % v.state)
    check(v.state == "unknown", "a failed read abstains; got %s" % v.state)

    with temp_store({"sessions": {"sid-1": {"pid": 1000, "pidStartSeconds": 1000, "cwd": "/x"}}}) as (path, d):
        with ps_env([], ps_fail=True):
            e = liv.gather("sid-1", store_path=path, sessions_dir=os.path.join(d, "sessions"), now_ms=NOW_MS)
    check(e.ps_ok is False, "gather must report ps_ok=False when the read failed")
    check(liv.evaluate(e).state != "dead", "a degraded gather must never produce dead")


# ══════════════════════════════════════════════════════════════════════════
# T5 — an empty candidate set abstains; "all are gone" is vacuously true of
# nothing (C4).
# ══════════════════════════════════════════════════════════════════════════
@test("T5 empty candidate set -> unknown (no-holder-record), never dead (C4)")
def t5_empty_candidate_set():
    v = liv.evaluate(ev(candidates=[]))
    check(v.state == "unknown", "an empty candidate set must abstain; got %s" % v.state)
    check(v.reason == "no-holder-record", "the abstention must be named; got %s" % v.reason)
    check(liv.is_dead_evidence([]) is False,
          "the dead predicate must require a NON-EMPTY candidate set (vacuity guard)")


# ══════════════════════════════════════════════════════════════════════════
# T6 — a zombie is a corpse, not a holder; a zombie pi with a frozen JSONL is
# dead (a dead lane must not read wedged).
# ══════════════════════════════════════════════════════════════════════════
@test("T6 zombie pi + frozen JSONL -> dead")
def t6_zombie():
    v = liv.evaluate(ev(candidates=[C(100, "zombie")]))
    check(v.state == "dead", "a zombie incarnation is gone; got %s/%s" % (v.state, v.reason))

    with ps_env([ps_row(4242, stat="Z", cmd="/usr/local/bin/pi <defunct>")]):
        res = liv.probe_pid(4242, PROBE_EPOCH)
    check(res.rc == 1 and res.status == "zombie",
          "a Z stat must be a zombie witness (exit 1); got rc=%s status=%s (%s)" % (res.rc, res.status, res.detail))
    v2 = liv.evaluate(ev(candidates=[C(4242, liv.observed_from_probe(res.rc, res.status))]))
    check(v2.state == "dead", "the zombie row must produce dead; got %s" % v2.state)

    check(liv.evaluate(ev(candidates=[C(4242, "zombie")])).state != "running-quiet", "a zombie is not liveness")


# ══════════════════════════════════════════════════════════════════════════
# T7 — ghost tag + live tag. The UNION is the safety rule: choosing the newest
# (or the first) record would call a live lane dead.
# ══════════════════════════════════════════════════════════════════════════
@test("T7 ghost tag + live tag -> running-quiet (the union, not one record)")
def t7_ghost_tag():
    cands = [C(100, "off-fence", start=1000), C(200, "holder", start=2000)]
    v = liv.evaluate(ev(candidates=cands, jsonl_age_ms=5 * M))
    check(v.state == "running-quiet", "a live tag must win over a ghost tag; got %s/%s" % (v.state, v.reason))
    check(v.holder_pid == 200, "the fenced live tag is the holder; got %s" % v.holder_pid)
    check(v.state != "dead", "a ghost tag must never make a live lane dead")


# ══════════════════════════════════════════════════════════════════════════
# T8 — JSONL growth with no fenced holder. Growth is positive liveness evidence,
# so it is running-quiet (exactly ONE verdict) and never dead (C6).
# ══════════════════════════════════════════════════════════════════════════
@test("T8 JSONL growing, no fenced holder -> running-quiet, never dead (C6)")
def t8_growth_without_holder():
    v = liv.evaluate(ev(candidates=[C(100, "absent")], jsonl_grew=True, jsonl_age_ms=0))
    check(v.state == "running-quiet", "growth is liveness: got %s/%s" % (v.state, v.reason))
    check(v.reason == "jsonl-grew(writer-unidentified)",
          "the evidence must name the un-fenced writer; got %s" % v.reason)
    check(v.state != "dead", "a growing lane must never be dead")

    v2 = liv.evaluate(ev(candidates=[], jsonl_grew=True, jsonl_age_ms=0))
    check(v2.state == "running-quiet",
          "growth with NO candidates is still exactly one verdict: running-quiet; got %s" % v2.state)

    check(v.state in liv.STATES and isinstance(v.reason, str) and v.reason,
          "a verdict is one state plus its reason")


# ══════════════════════════════════════════════════════════════════════════
# T9 — the hung-tool veto expires at the WATCHDOG's per-shape bound (C5): S = 20
# min (tool-silence), 30 min (tool-dead's CPU conjunct), and the age backstop's
# 4h while the turn is ACTIVE / min(4h, 30min) when it is NOT.
# ══════════════════════════════════════════════════════════════════════════
@test("T9 hung tool: the veto expires at the watchdog's per-shape bound, incl. turn-inactive 30min (C5)")
def t9_hung_tool_bound():
    def hung(**kw):
        base = dict(tools_in_flight=1, tool_updates=False, cpu_advanced=False)
        base.update(kw)
        return liv.Tool(**base)

    # (a) 3h, zero CPU, zero output, turn ACTIVE -> the 4h age backstop -> quiet.
    v = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=3 * H,
                        tool=hung(tool_age_ms=3 * H, turn_active=True)))
    check(v.state == "running-quiet",
          "a 3h hung tool under the ACTIVE 4h backstop is still running-quiet; got %s/%s" % (v.state, v.reason))

    # (b) turn INACTIVE -> bound = min(4h, 30min) = 30min -> 31min expires it.
    v2 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=31 * M,
                         tool=hung(tool_age_ms=31 * M, turn_active=False), jsonl_turn=OPEN_TURN))
    check(v2.state == "wedged",
          "a turn-inactive hung tool past 30min is wedged-eligible; got %s/%s" % (v2.state, v2.reason))

    # (c) 29min turn-inactive -> still vetoing (the bound is not too eager).
    v3 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=29 * M,
                         tool=hung(tool_age_ms=29 * M, turn_active=False)))
    check(v3.state == "running-quiet", "29min is inside the turn-inactive bound; got %s" % v3.state)

    # (d) the comparison is STRICT `>`: exactly at the bound does not expire.
    v4 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=30 * M,
                         tool=hung(tool_age_ms=30 * M, turn_active=False)))
    check(v4.state == "running-quiet", "exactly at the bound must NOT expire (strict >); got %s" % v4.state)

    # (e) tool-silence shape: S = 20min, not load-scaled, and not 4h. Since
    #     #5389 the clause ALSO requires positive no-progress evidence, so the
    #     fixture arms the CPU channel (as the watchdog's own #5389 fixtures do)
    #     instead of relying on silence alone — silence alone is now `unknown`,
    #     which correctly falls to the age backstop rather than expiring.
    stopped = dict(tool_updates=True, cpu_advanced=True, cpu_stall_ms=31 * M)
    v5 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=21 * M,
                         tool=hung(silence_age_ms=21 * M, tool_age_ms=31 * M, **stopped),
                         jsonl_turn=OPEN_TURN))
    check(v5.state == "wedged",
          "a streamed-then-silent, CPU-flat tool past S=20min is wedged-eligible; got %s/%s"
          % (v5.state, v5.reason))
    v6 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=19 * M,
                         tool=hung(silence_age_ms=19 * M, tool_age_ms=31 * M, **stopped)))
    check(v6.state == "running-quiet", "19min is inside S; got %s" % v6.state)

    check(liv.tool_stall_ms() == 4 * H,
          "getToolStallMs() == 2/3 x 6h = 4h; got %s" % liv.tool_stall_ms())
    check(liv.STREAM_STALL_MS == 20 * M, "S is the watchdog's DEFAULT_STREAM_STALL_MS (20min)")


# ══════════════════════════════════════════════════════════════════════════
# T10 — the input-consumption veto is BOUNDED at 72h, and it NEVER gates dead
# (C9, #947).
# ══════════════════════════════════════════════════════════════════════════
@test("T10 non-idle record: stale past 72h does not veto; fresh does; dead is never vetoed (C9)")
def t10_record_veto_bound():
    stale = liv.Record(non_idle=True, updated_at=NOW_S - 100 * 3600)
    fresh = liv.Record(non_idle=True, updated_at=NOW_S - 3600)

    v = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=30 * M, record=stale,
                        jsonl_turn=OPEN_TURN))
    check(v.state == "wedged",
          "a non-idle record stale past 72h must not immunise the lane; got %s/%s" % (v.state, v.reason))

    v2 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=30 * M, record=fresh))
    check(v2.state == "running-quiet",
          "a FRESH non-idle record vetoes wedged; got %s/%s" % (v2.state, v2.reason))
    # #1273: the veto's reason is named in the corrected prose (how a
    # turn-ended lane reaches running-quiet), so it is pinned here rather than
    # asserted in prose alone.
    check(v2.reason == "record-non-idle-fresh",
          "the veto names its own reason; got %s" % v2.reason)

    v3 = liv.evaluate(ev(candidates=[C(1, "absent")], jsonl_grew=False, jsonl_age_ms=H, record=fresh))
    check(v3.state == "dead",
          "a record must NEVER veto dead — that re-creates the five-hour loss; got %s/%s" % (v3.state, v3.reason))

    v4 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=30 * M,
                         record=liv.Record(non_idle=True, updated_at=None)))
    check(v4.state == "running-quiet",
          "an unusable updatedAt keeps the veto (fail closed); got %s" % v4.state)

    v5 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=30 * M,
                         record=liv.Record(non_idle=False, updated_at=NOW_S - 3600),
                         jsonl_turn=OPEN_TURN))
    check(v5.state == "wedged", "an idle record never vetoes; got %s" % v5.state)

    check(liv.RECORD_VETO_MS == 72 * H, "the #947 bound is 3 x 24h = 72h")


# ══════════════════════════════════════════════════════════════════════════
# T11 — a legitimately CPU-flat nested `task` must not read wedged (C8): the
# watchdog's CPU attribution allowlist is {"bash"} and excludes `task`.
# ══════════════════════════════════════════════════════════════════════════
@test("T11 nested task, CPU-flat -> not wedged (C8)")
def t11_nested_task_cpu_flat():
    flat = dict(tools_in_flight=1, tool_updates=False, cpu_advanced=True,
                cpu_stall_ms=35 * M, tool_age_ms=35 * M, turn_active=True)

    task = liv.Tool(name="task", **flat)
    check(liv.cpu_attributable(task) is False, "`task` is deliberately absent from the CPU allowlist")
    v = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=35 * M, tool=task))
    check(v.state == "running-quiet",
          "a CPU-flat nested task is legitimately quiet, not wedged; got %s/%s" % (v.state, v.reason))

    bash = liv.Tool(name="bash", **flat)
    check(liv.cpu_attributable(bash) is True, "`bash` IS attributable")
    v2 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=35 * M, tool=bash,
                         jsonl_turn=OPEN_TURN))
    check(v2.state == "wedged",
          "the same shape for an attributable tool IS wedged-eligible (tool-dead); got %s" % v2.state)

    check(liv.CPU_LIVENESS_TOOL_NAMES == frozenset({"bash"}),
          "the allowlist must be exactly the watchdog's CPU_LIVENESS_TOOL_NAMES")


# ══════════════════════════════════════════════════════════════════════════
# T12 — evidence insufficiency abstains with a NAMED reason; it never guesses a
# verdict (and never manufactures dead).
# ══════════════════════════════════════════════════════════════════════════
@test("T12 missing/garbage store or ps -> unknown + a named reason")
def t12_named_abstention():
    v = liv.evaluate(ev(store_ok=False, candidates=[]))
    check(v.state == "unknown" and v.reason == "store-unreadable",
          "an unreadable store must abstain naming the store; got %s/%s" % (v.state, v.reason))

    v2 = liv.evaluate(ev(ps_ok=False, candidates=[C(1, "absent")]))
    check(v2.state == "unknown" and v2.reason == "ps-unreadable",
          "an unreadable ps must abstain naming ps; got %s/%s" % (v2.state, v2.reason))
    check(v2.state != "dead", "an unreadable ps must never manufacture dead")

    v3 = liv.evaluate(ev(candidates=[C(1, "unreadable")]))
    check(v3.state == "unknown" and v3.state != "dead",
          "a garbage probe result abstains; got %s/%s" % (v3.state, v3.reason))

    v4 = liv.evaluate(ev(candidates=[C(1, "absent")], jsonl_grew=None, jsonl_age_ms=None))
    check(v4.state == "unknown" and v4.reason == "jsonl-age-unknown",
          "an unreadable JSONL cannot prove non-growth -> abstain; got %s/%s" % (v4.state, v4.reason))

    with temp_store("{not json") as (path, _d):
        ok, sessions = liv.load_store(path)
    check(ok is False and sessions == {}, "a corrupt store must fail closed")
    with temp_store({"version": 1, "agentHookFailureReportTimestamps": {}}) as (path2, _d2):
        ok2, _ = liv.load_store(path2)
    check(ok2 is False, "a store with no session records must fail closed")

    # every abstention names itself — never a bare "unknown".
    for verdict in (v, v2, v3, v4):
        check(verdict.reason and verdict.reason != "unknown",
              "an abstention must carry a NAMED reason; got %r" % verdict.reason)


# ══════════════════════════════════════════════════════════════════════════
# T13 — a frozen transcript is NOT a stall (#1254). A turn that ended with a
# terminal stopReason is RESTING: the fleet's normal state. It must never read
# `wedged`, however long it is quiet short of the retirement proof.
# ══════════════════════════════════════════════════════════════════════════
@test("T13 turn-ended + frozen -> running-quiet/turn-ended, never wedged (#1254)")
def t13_turn_ended_is_not_wedged():
    complete = liv.turn_from_entry(entry("assistant", stopReason="stop"))
    check(complete.stalled is False, "a terminal stopReason ends the turn; got %s" % complete)
    check(complete.reason == "turn-ended", "the boundary names itself; got %s" % complete.reason)

    for age in (21 * M, H, 23 * H):
        v = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=age, jsonl_turn=complete))
        check(v.state == "running-quiet",
              "a resting lane must be running-quiet; got %s/%s at age=%d" % (v.state, v.reason, age))
        check(v.reason == "turn-ended", "the reason names the boundary; got %s" % v.reason)
        check(v.holder_pid == 1, "the fenced holder is still named; got %s" % v.holder_pid)

    # EVERY terminal stopReason on a message carrying NO tool calls ends the
    # turn — the call-carrying cases are T18's (#1254 P0).
    for stop in ("stop", "length", "error", "aborted"):
        t = liv.turn_from_entry(entry("assistant", stopReason=stop))
        v = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=2 * H, jsonl_turn=t))
        check(v.state == "running-quiet" and v.reason == "turn-ended",
              "stopReason=%s is terminal; got %s/%s" % (stop, v.state, v.reason))

    # The retirement proof is UNCHANGED: past it the lane is `idle`, not resting
    # and not wedged (the reaper's own 24h proof still owns that band).
    v_idle = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=25 * H,
                             jsonl_turn=complete))
    check(v_idle.state == "idle" and v_idle.reason == "jsonl-old",
          "past the idle proof a turn-ended lane is idle; got %s/%s" % (v_idle.state, v_idle.reason))


# ══════════════════════════════════════════════════════════════════════════
# T14 — the inverse, and the whole point of the fix: a transcript frozen with an
# OPEN turn IS a stall, and the verdict names the open call so the report says
# WHY. Dropping this half would make `wedged` unreachable (the fail-open
# direction) — the #1178 incident shape.
# ══════════════════════════════════════════════════════════════════════════
@test("T14 a frozen OPEN turn -> wedged, naming the open call (#1254)")
def t14_open_turn_is_wedged():
    t = liv.turn_from_entry(assistant_tooluse(("bash", "call_00_ABC"), ("read", "call_01_DEF")))
    check(t.stalled is True, "an unanswered tool call is an open turn; got %s" % t)
    check(t.reason == "turn-open:pending-tool-call", "the open shape is named; got %s" % t.reason)
    v = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=21 * M, jsonl_turn=t))
    check(v.state == "wedged", "an open turn frozen past S is a stall; got %s/%s" % (v.state, v.reason))
    check(v.reason == "turn-open:pending-tool-call", "the reason names the open shape; got %s" % v.reason)
    check("bash" in v.detail and "call_00_ABC" in v.detail,
          "the verdict names the unanswered call; got detail=%r" % v.detail)

    tr = liv.turn_from_entry(entry("toolResult", toolName="bash", toolCallId="call_00_XYZ",
                                   content=[{"type": "text", "text": "ok"}]))
    check(tr.stalled is True and tr.reason == "turn-open:awaiting-assistant",
          "a toolResult with no reply after it is an open turn; got %s" % tr)
    v2 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=21 * M, jsonl_turn=tr))
    check(v2.state == "wedged", "a toolResult frozen past S is a stall; got %s" % v2.state)
    check("call_00_XYZ" in v2.detail, "the verdict names the result's call; got %r" % v2.detail)

    u = liv.turn_from_entry(entry("user", content=[{"type": "text", "text": "hello"}]))
    check(u.stalled is True and u.reason == "turn-open:awaiting-response",
          "an unanswered prompt is an open turn; got %s" % u)
    v3 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=21 * M, jsonl_turn=u))
    check(v3.state == "wedged", "an unanswered prompt frozen past S is a stall; got %s" % v3.state)

    ns = liv.turn_from_entry(entry("assistant", content=[{"type": "text", "text": "x"}]))
    check(ns.stalled is True and ns.reason == "turn-open:no-terminal-stop",
          "an assistant message with no stopReason is not terminal; got %s" % ns)


# ══════════════════════════════════════════════════════════════════════════
# T15 — the boundary is the transcript's LAST entry. A forward scan would return
# an ancient turn and call a live mid-turn lane resting (or the reverse), which
# is why the read is bounded AND backwards. Non-message trailers (a compaction
# / model_change record) carry no boundary and must not change the answer.
# ══════════════════════════════════════════════════════════════════════════
@test("T15 the turn boundary is the transcript's LAST entry, read backwards (#1254)")
def t15_tail_read():
    d = tempfile.mkdtemp(prefix="liv-jsonl-")
    try:
        path = os.path.join(d, "session.jsonl")
        lines = [
            entry("user", content=[{"type": "text", "text": "hello"}]),
            entry("assistant", stopReason="stop", content=[{"type": "text", "text": "early"}]),
            assistant_tooluse(("bash", "call_LAST")),
        ]
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(json.dumps(e) for e in lines) + "\n")
        t = liv.turn_from_jsonl(path)
        check(t is not None and t.stalled is True,
              "the LAST (open) boundary decides, not the first; got %s" % t)
        check("call_LAST" in t.detail, "the last call is the one named; got %r" % t.detail)

        # A compaction trailer is not a turn boundary AT ALL: it abstains (#1254
        # P1, T19) rather than letting the open turn before it decide.
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"type": "compaction", "summary": "…"}) + "\n")
        t2 = liv.turn_from_jsonl(path)
        check(t2 is not None and t2.abstain is True and t2.reason == "tail-after-compaction",
              "a compaction trailer abstains rather than deciding; got %s" % t2)
        # A NON-compaction trailer keeps the boundary: the last message decides.
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"type": "model_change"}) + "\n")
        t2b = liv.turn_from_jsonl(path)
        check(t2b is not None and "call_LAST" in t2b.detail,
              "a non-compaction trailer must not change the boundary; got %s" % t2b)

        # A terminal assistant message flips it to resting.
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry("assistant", stopReason="stop",
                                      content=[{"type": "text", "text": "done"}])) + "\n")
        t3 = liv.turn_from_jsonl(path)
        check(t3 is not None and t3.stalled is False and t3.reason == "turn-ended",
              "the new last entry flips the verdict; got %s" % t3)

        # gather() wires the boundary in (hermetic store + probe shims).
        sessions = os.path.join(d, "sessions")
        os.makedirs(os.path.join(sessions, "--x--"))
        sfile = os.path.join(sessions, "--x--", "2026-01-01T00-00-00-000Z_sid-1.jsonl")
        shutil.copy(path, sfile)
        os.utime(sfile, (NOW_S - 1800, NOW_S - 1800))
        payload = {"sessions": {"sid-1": {"pid": 555, "pidStartSeconds": PROBE_EPOCH,
                                           "cwd": "/x", "agentLifecycle": "idle",
                                           "runtimeStatus": "idle"}}}
        with temp_store(payload) as (store, _sd):
            with ps_env([ps_row(555)]):
                e = liv.gather("sid-1", store_path=store, sessions_dir=sessions, now_ms=NOW_MS)
        check(e.jsonl_turn is not None and e.jsonl_turn.stalled is False,
              "gather must carry the boundary; got %s" % e.jsonl_turn)
        check(e.jsonl_age_ms is not None and e.jsonl_age_ms > liv.STREAM_STALL_MS,
              "the fixture must be frozen past S; got %s" % e.jsonl_age_ms)
        g = liv.evaluate(e)
        check(g.state == "running-quiet" and g.reason == "turn-ended",
              "a turn-ended lane past S is resting, not wedged; got %s/%s" % (g.state, g.reason))
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ══════════════════════════════════════════════════════════════════════════
# T16 — `dead` is untouched. It is decided from fenced-holder identity BEFORE
# the ladder, so no turn classification may reach it: a turn-ended lane whose
# every incarnation is gone is STILL dead, and a stalled one is too. Nothing
# added for #1254 may move the one state the classifier exists to report.
# ══════════════════════════════════════════════════════════════════════════
@test("T16 dead is decided before the turn ladder — never gated by turn state (#1254)")
def t16_dead_unchanged():
    for turn in (None, COMPLETE_TURN, OPEN_TURN,
                 liv.Turn(True, "turn-open:awaiting-response", "user prompt")):
        v = liv.evaluate(ev(candidates=[C(100, "absent")], jsonl_grew=False,
                            jsonl_age_ms=H, jsonl_turn=turn))
        check(v.state == "dead",
              "a gone incarnation is dead whatever the turn state; got %s/%s" % (v.state, v.reason))
        check("100:absent" in v.witnesses, "the death witness is named; got %s" % (v.witnesses,))
        check(v.holder_pid is None, "dead has no holder; got %s" % v.holder_pid)

    check(liv.is_dead_evidence([]) is False, "the dead predicate stays non-vacuous")
    check(liv.is_dead_evidence([C(1, "off-fence")]) is False, "off-fence is not a death witness")
    check(liv.is_dead_evidence([C(1, "absent")]) is True, "absent is the death witness")


# ══════════════════════════════════════════════════════════════════════════
# T17 — absence of turn evidence is an ABSTENTION, and the bounds are verbatim.
# An unreadable boundary must not fall into `wedged` (that is the original
# defect with a different trigger), an OPEN turn inside S is still just quiet,
# and no bound is load-rescaled.
# ══════════════════════════════════════════════════════════════════════════
@test("T17 unclassifiable turn -> unknown; bounds verbatim and unscaled (#1254)")
def t17_unknown_turn_and_bounds():
    v = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=21 * M, jsonl_turn=None))
    check(v.state == "unknown", "an unreadable boundary abstains; got %s/%s" % (v.state, v.reason))
    check(v.reason == "turn-state-unknown", "the abstention is named; got %s" % v.reason)

    v2 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=19 * M, jsonl_turn=OPEN_TURN))
    check(v2.state == "running-quiet" and v2.reason == "quiet-within-bound",
          "an open turn inside S is still quiet; got %s/%s" % (v2.state, v2.reason))
    v3 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=20 * M, jsonl_turn=OPEN_TURN))
    check(v3.state == "running-quiet", "exactly at S does NOT yet license wedged (strict >); got %s" % v3.state)
    v4 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=20 * M + 1, jsonl_turn=OPEN_TURN))
    check(v4.state == "wedged", "one ms past S does; got %s" % v4.state)

    check(liv.STREAM_STALL_MS == 20 * M, "S is the watchdog's verbatim 20min bound; got %s" % liv.STREAM_STALL_MS)
    check(liv.IDLE_MS == 24 * H, "the idle proof is the reaper's verbatim 24h; got %s" % liv.IDLE_MS)
    check(liv.turn_from_jsonl(None) is None, "no path is no boundary")
    check(liv.turn_from_jsonl("/nonexistent/nope.jsonl") is None, "an unreadable file is no boundary")


# ══════════════════════════════════════════════════════════════════════════
# T18 — the cycle-1 P0 (#1254). A message CARRYING tool calls is OPEN unless its
# stop reason is one under which pi DISCARDS the calls. On `length` pi FAILS the
# calls and CONTINUES the turn, so a `length` message with calls leaves the turn
# open, not resting. Measured over the 426 live session files in
# ~/.pi/agent/sessions: toolUse 147,466 with calls / 147,431 with a following
# result; error 115 with calls / 0 with a result; length 78 with calls / 78 with
# a result — EVERY one of those 78 results is `isError: true` ("Tool call ... was
# not executed"), i.e. the calls were FAILED, not executed; aborted 16 with calls
# / 0 with a result.
# ══════════════════════════════════════════════════════════════════════════
@test("T18 tool calls decide openness: `length`+calls OPEN, `error`/`aborted`+calls ENDED (#1254 P0)")
def t18_call_carrying_stop_reasons():
    # (a) `length` with calls leaves the turn OPEN — pi fails those calls
    #     (`failToolCallsFromTruncatedMessage`; all 78 results carry isError).
    t = liv.turn_from_entry(entry("assistant", stopReason="length",
                                  content=[{"type": "toolCall", "name": "bash",
                                            "id": "call_00_LEN"}]))
    check(t.stalled is True, "`length` with calls is an open turn; got %s" % t)
    check(t.reason == "turn-open:pending-tool-call", "the open shape is named; got %s" % t.reason)
    v = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=21 * M, jsonl_turn=t))
    check(v.state == "wedged", "a `length`+calls turn frozen past S is a stall; got %s/%s" % (v.state, v.reason))
    check("call_00_LEN" in v.detail, "the verdict names the unanswered call; got %r" % v.detail)

    # (b) `error` and `aborted` DISCARD their calls (0/115, 0/16) -> ENDED.
    for stop in ("error", "aborted"):
        t2 = liv.turn_from_entry(entry("assistant", stopReason=stop,
                                       content=[{"type": "toolCall", "name": "bash",
                                                 "id": "call_00_%s" % stop}]))
        check(t2.stalled is False and t2.reason == "turn-ended",
              "`%s` discards its calls and ends the turn; got %s" % (stop, t2))
        v2 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=21 * M, jsonl_turn=t2))
        check(v2.state == "running-quiet" and v2.reason == "turn-ended",
              "a `%s`+calls lane is resting, never wedged; got %s/%s" % (stop, v2.state, v2.reason))

    # (c) a TERMINAL stopReason with NO tool calls stays ended — the resting case
    # #1254 fixed must not regress.
    for stop in ("stop", "length", "error", "aborted"):
        t3 = liv.turn_from_entry(entry("assistant", stopReason=stop,
                                       content=[{"type": "text", "text": "done"}]))
        check(t3.stalled is False and t3.reason == "turn-ended",
              "stopReason=%s with no calls is terminal; got %s" % (stop, t3))

    # (d) `toolUse` with no parseable call is still non-terminal.
    t4 = liv.turn_from_entry(entry("assistant", stopReason="toolUse"))
    check(t4.stalled is True and t4.reason == "turn-open:pending-tool-call",
          "`toolUse` with no parseable call is still open; got %s" % t4)

    check(liv.CALL_DISCARDING_STOP_REASONS == frozenset({"error", "aborted"}),
          "the discard set is exactly the measured discarders; got %s" % liv.CALL_DISCARDING_STOP_REASONS)


# ══════════════════════════════════════════════════════════════════════════
# T19 — the cycle-1 P1 (#1254). A `compaction` as the LAST entry is an
# ABSTENTION: pi writes it BETWEEN turns (483 compaction entries over the 426
# live session files, 477 followed by a message entry and 357 of those an open
# assistant/toolUse), so it is not evidence that the turn before it ended.
# ══════════════════════════════════════════════════════════════════════════
@test("T19 compaction tail -> unknown/tail-after-compaction, never a decided turn (#1254 P1)")
def t19_compaction_tail_abstains():
    d = tempfile.mkdtemp(prefix="liv-compaction-")
    try:
        path = os.path.join(d, "session.jsonl")

        def write(entries):
            with open(path, "w", encoding="utf-8") as fh:
                for e in entries:
                    fh.write(json.dumps(e) + "\n")

        # A terminal assistant message followed by a compaction: the compaction
        # must not let the terminal message decide (it is not evidence of rest).
        write([entry("assistant", stopReason="stop", content=[{"type": "text", "text": "ok"}]),
               {"type": "compaction", "summary": "…"}])
        t = liv.turn_from_jsonl(path)
        check(t is not None and t.abstain is True, "a compaction tail abstains; got %s" % t)
        check(t.reason == "tail-after-compaction", "the abstention is named; got %s" % t.reason)
        v = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=21 * M, jsonl_turn=t))
        check(v.state == "unknown" and v.reason == "tail-after-compaction",
              "a compaction tail is unknown, never wedged and never resting; got %s/%s"
              % (v.state, v.reason))

        # The OPEN shape is the fail-open case: an open turn + a compaction tail
        # must NOT fall through to `wedged`.
        write([assistant_tooluse(("bash", "call_00_OPEN")),
               {"type": "compaction", "summary": "…"}])
        t2 = liv.turn_from_jsonl(path)
        check(t2 is not None and t2.abstain is True and t2.reason == "tail-after-compaction",
              "an open turn + compaction tail abstains rather than wedging; got %s" % t2)
        v2 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=21 * M, jsonl_turn=t2))
        check(v2.state == "unknown", "the open-turn compaction tail is an abstention; got %s" % v2.state)

        # Other trailers keep the existing behaviour: the previous message decides.
        for trailer in ("model_change", "session", "thinking_level_change"):
            write([entry("assistant", stopReason="stop", content=[{"type": "text", "text": "ok"}]),
                   {"type": trailer}])
            t3 = liv.turn_from_jsonl(path)
            check(t3 is not None and t3.stalled is False and t3.reason == "turn-ended",
                  "a %s trailer leaves the previous message deciding; got %s" % (trailer, t3))
        write([assistant_tooluse(("bash", "call_00_NEXT")), {"type": "model_change"}])
        t4 = liv.turn_from_jsonl(path)
        check(t4 is not None and t4.stalled is True and "call_00_NEXT" in t4.detail,
              "a non-compaction trailer keeps the open boundary; got %s" % t4)

        # A non-message, non-compaction entry passed directly carries no boundary.
        check(liv.turn_from_entry({"type": "model_change"}).reason == "no-turn-yet",
              "turn_from_entry stays total for a non-message entry")
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ══════════════════════════════════════════════════════════════════════════
# T20 — the classifier's default is FAIL-CLOSED (#1272). `turn-ended` is an
# explicit terminal SET, not the fall-through for every stop reason the code has
# never seen. `turn-ended` means RESTING — unescalatable and never `wedged` — so
# a default that lands there reads a genuinely suspended lane as merely quiet,
# the fail-open shape the module's own principle forbids.
#
# Terminality (`TERMINAL_STOP_REASONS`): `stop` and `length` end a completed
# turn; `error` and `aborted` END THE AGENT RUN outright — pi's loop returns
# before any tool batch (`pi-agent-core/dist/agent-loop.js:124-128`) — so all
# four are terminal on a CALL-FREE message. On a message CARRYING calls the
# call-carrying rule is decided FIRST, so `length`/`stop` + calls stay OPEN and
# an unrecognized reason + calls is OPEN too; only a call-free unrecognized
# reason ABSTAINS, naming the value.
#
# Reachability: measured over 7,820 transcripts / 384,657 assistant messages in
# ~/.pi/agent/sessions and ~/.pi/agent/task-sessions, the only stopReason values
# that occur are exactly `stop` / `toolUse` / `error` / `length` / `aborted`, so
# the abstention is LATENT today (0 cases). What this pins is the DEFAULT's
# direction, not a live misclassification; `pending` (pi-ai's in-flight
# placeholder) and `deferred` (settled by pi's harness runtime as
# `deferred.suspended`) are values pi's contract names but the corpus does not
# yet produce, and both are deliberately NOT terminal.
# ══════════════════════════════════════════════════════════════════════════
@test("T20 an unrecognized stopReason ABSTAINS (turn-unknown:<value>), never turn-ended (#1272)")
def t20_unrecognized_stop_reason_abstains():
    # (a) The four KNOWN terminal values still end the turn on a call-free
    #     message — the fix changes the default, not the decisions.
    for stop in ("stop", "length", "error", "aborted"):
        t = liv.turn_from_entry(entry("assistant", stopReason=stop,
                                      content=[{"type": "text", "text": "…"}]))
        check(t.stalled is False and t.reason == "turn-ended" and t.abstain is False,
              "`%s` with no calls still ends the turn; got %s" % (stop, t))

    # (b) An unrecognized, non-terminal value with no calls is NOT `turn-ended`:
    #     it abstains, names the value, and the ladder returns `unknown`.
    for stop in ("deferred", "deferred.suspended", "pending", "quotaExceeded"):
        t2 = liv.turn_from_entry(entry("assistant", stopReason=stop,
                                       content=[{"type": "text", "text": "…"}]))
        check(t2.stalled is False,
              "an unrecognized stop reason is not POSITIVELY open; got %s" % t2)
        check(t2.abstain is True,
              "an unrecognized stop reason must ABSTAIN, never read as resting; got %s" % t2)
        check(t2.reason == "turn-unknown:%s" % stop,
              "the abstention names the unrecognized value; got %s" % t2.reason)
        v = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=21 * M, jsonl_turn=t2))
        check(v.state == "unknown" and v.reason == "turn-unknown:%s" % stop,
              "`%s` frozen past S is unknown, never resting and never wedged; got %s/%s"
              % (stop, v.state, v.reason))

    # (c) The non-terminal set is untouched: `toolUse` with no parseable call is
    #     still an open turn, and a missing stopReason still reads open.
    t3 = liv.turn_from_entry(entry("assistant", stopReason="toolUse",
                                   content=[{"type": "text", "text": "…"}]))
    check(t3.stalled is True and t3.reason == "turn-open:pending-tool-call",
          "`toolUse` with no parseable call is still open; got %s" % t3)
    t4 = liv.turn_from_entry(entry("assistant", content=[{"type": "text", "text": "…"}]))
    check(t4.stalled is True and t4.reason == "turn-open:no-terminal-stop",
          "a missing stopReason is still open; got %s" % t4)

    # (d) The call-carrying rule is decided FIRST and outranks the new
    #     abstention: `stop`+calls and an UNRECOGNIZED reason + calls are OPEN
    #     (NOT an abstention), because the message may be awaiting its results.
    for stop in ("stop", "deferred", "quotaExceeded"):
        t5 = liv.turn_from_entry(entry("assistant", stopReason=stop,
                                       content=[{"type": "toolCall", "name": "bash",
                                                 "id": "call_00_%s" % stop}]))
        check(t5.stalled is True and t5.abstain is False
              and t5.reason == "turn-open:pending-tool-call",
              "`%s`+calls is an OPEN turn, never an abstention; got %s" % (stop, t5))
        v5 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=21 * M, jsonl_turn=t5))
        check(v5.state == "wedged",
              "`%s`+calls frozen past S is a stall, not resting; got %s/%s"
              % (stop, v5.state, v5.reason))

    # (e) The terminal set is a DECISION, not a fall-through: it must not be
    #     empty (then nothing reads resting) and must contain the four measured
    #     terminal values.
    check(liv.TERMINAL_STOP_REASONS == frozenset({"stop", "length", "error", "aborted"}),
          "the terminal set is explicit; got %s" % (liv.TERMINAL_STOP_REASONS,))
    check(liv.NON_TERMINAL_STOP_REASONS == frozenset({"toolUse"}),
          "the non-terminal set is unchanged; got %s" % (liv.NON_TERMINAL_STOP_REASONS,))


def _claim(scope="local", lease="live", pid=93756):
    """A ref-claim row for the #1777 tests (the incident's own shape)."""
    host = {"local": "Daniels-MacBook-Air-new", "foreign": "cmux", "unknown": ""}.get(scope, "")
    return liv.Claim(
        ref="refs/claims/8697-f5282009634e", key="8697-f5282009634e", pr="8697",
        sha12="f5282009634e", owner="%s:%d" % (host, pid) if scope != "unknown" else "?",
        owner_host=host, owner_pid=(pid if scope != "unknown" else None),
        lease_until=(NOW_S + 1800 if lease == "live" else (NOW_S - 1800 if lease == "expired" else None)),
        lease_state=lease, scope=scope, commit="c0ffee", age_s=600,
    )


def _claim_ev(**kw):
    kw.setdefault("candidates", [])
    return ev(**kw)


@test("T25 an unreadable ref-claim namespace ABSTAINS (claims-unreadable), never dead (#1777)")
def t25_claims_unreadable_abstains():
    cr = liv.ClaimRead(readable=False, present=False, claims=(),
                       source="origin:https://example.invalid/r.git",
                       detail="ls-remote rc=128 (auth)")
    v = liv.evaluate(_claim_ev(claim_read=cr))
    check(v.state == "unknown",
          "an unreadable namespace is an abstention, never free/dead; got %s" % v.state)
    check(v.reason == "claims-unreadable", "the abstention is named; got %s" % v.reason)
    check(v.holder_pid is None, "no incarnation may be asserted from an unreadable read")
    check("rc=128" in v.detail, "the cause is surfaced; got %r" % v.detail)
    # The load-bearing distinction: unreadable is NOT an absence — proven by the
    # reason CHANGING when the same empty claim set is readable, not by re-asserting
    # the fixture we just built (a self-fulfilling check proves nothing).
    v_empty = liv.evaluate(_claim_ev(claim_read=liv.ClaimRead(readable=True, present=False)))
    check(v_empty.reason == "no-claim-visible" and v_empty.reason != v.reason,
          "an unreadable read and a genuinely empty read must be DIFFERENT reasons")


@test("T26 a readable namespace with no claim ABSTAINS (no-claim-visible) and declares the gap (#1777)")
def t26_no_claim_visible_abstains():
    cr = liv.ClaimRead(readable=True, present=False, claims=(),
                       siblings=("1525-aaaaaaaaaaaa",), source="origin:x")
    v = liv.evaluate(_claim_ev(claim_read=cr))
    check(v.state == "unknown", "no claim visible must not read as free; got %s" % v.state)
    check(v.reason == "no-claim-visible", "got %s" % v.reason)
    # The disclosure is the fix: the read declares the gap it cannot cover.
    check("NOT freedom" in v.detail, "the absence disclosure is rendered; got %r" % v.detail)
    check("HEAD-scoped" in v.detail, "the HEAD-scoping is named; got %r" % v.detail)
    check("1525-aaaaaaaaaaaa" in v.detail,
          "the other heads of the PR are disclosed rather than silently dropped; got %r" % v.detail)
    check(liv.NO_CLAIM_DISCLOSURE in v.detail, "the fixed disclosure text is used verbatim")


@test("T27 a claim verdict NEVER sets holder_pid; owner identity rides in detail (#1777/#1178)")
def t27_claim_never_sets_holder_pid():
    live = _claim(scope="local", lease="live")
    for cr in (liv.ClaimRead(readable=True, present=True, claims=(live,)),
               liv.ClaimRead(readable=True, present=True, claims=(_claim(scope="foreign"),)),
               liv.ClaimRead(readable=True, present=True,
                             claims=(_claim(scope="local", lease="expired"),))):
        v = liv.evaluate(_claim_ev(claim_read=cr))
        check(v.holder_pid is None,
              "a claim records no process start, so no incarnation may be asserted; got %r"
              % (v.holder_pid,))
    v = liv.evaluate(_claim_ev(claim_read=liv.ClaimRead(readable=True, present=True,
                                                       claims=(live,))))
    check(v.state == "unknown" and v.reason == "claim-held", "got %s/%s" % (v.state, v.reason))
    # "who holds this?" IS answered — as non-liveness detail.
    check("owner=Daniels-MacBook-Air-new:93756" in v.detail,
          "the owner identity is reported; got %r" % v.detail)
    check("lease=live" in v.detail and "scope=local" in v.detail,
          "the lease state and scope are reported; got %r" % v.detail)
    check("age_s=600" in v.detail,
          "the claim age is reported as non-liveness detail; got %r" % v.detail)
    check("not asserted" in v.detail,
          "the reason states that process liveness is NOT asserted; got %r" % v.detail)


@test("T28 EVERY claim-shaped verdict ABSTAINS: unknown, named, no holder_pid (#1777 adversarial B1-B9)")
def t28_claim_verdicts_all_abstain():
    seen = set()
    for readable in (True, False):
        for present in (True, False):
            for scope in ("local", "foreign", "unknown"):
                for lease in ("live", "expired", "unknown"):
                    claims = (_claim(scope=scope, lease=lease),) if present else ()
                    cr = liv.ClaimRead(readable=readable, present=present, claims=claims,
                                       source="origin:x")
                    v = liv.evaluate(_claim_ev(claim_read=cr))
                    check(v.state == "unknown",
                          "readable=%s present=%s scope=%s lease=%s -> %s (must be unknown)"
                          % (readable, present, scope, lease, v.state))
                    check(v.reason in liv.CLAIM_REASONS, "unlisted reason %r" % (v.reason,))
                    check(v.holder_pid is None, "no claim verdict may set holder_pid")
                    # lane_liveness escalates `dead` ONLY; an unknown can never file.
                    check(v.state not in ("dead", "wedged", "idle", "running-quiet"),
                          "a claim-shaped query must never reach a session state; got %s" % v.state)
                    seen.add(v.reason)
    check(seen == set(liv.CLAIM_REASONS),
          "the six reasons must be a PARTITION: reachable+exhaustive; got %s" % sorted(seen))
    check(len(liv.CLAIM_REASONS) == 6, "the reason set is explicit; got %r" % (liv.CLAIM_REASONS,))
    # The five-state vocabulary still has exactly five states — a claim adds no state.
    check(liv.STATES == ("dead", "running-quiet", "wedged", "idle", "unknown"),
          "the state vocabulary is unchanged; got %r" % (liv.STATES,))


@test("T29 session evidence OUTRANKS a claim; dead stays unreachable for a claim (#1777)")
def t29_claims_do_not_override_session_evidence():
    live = _claim(scope="local", lease="live")
    cr = liv.ClaimRead(readable=True, present=True, claims=(live,))
    # (a) A growing transcript is positive liveness evidence — decided first, so a
    #     claim can never suppress it.
    v = liv.evaluate(ev(candidates=[], jsonl_grew=True, claim_read=cr))
    check(v.state == "running-quiet" and v.reason.startswith("jsonl-grew"),
          "a growing lane still reads jsonl-grew over a claim; got %s/%s" % (v.state, v.reason))
    check(v.reason != "claim-held", "the claim must not have decided this verdict")
    # (b) A session lane whose incarnations are gone still reads dead — a claim
    #     attached to it must not change that.
    v2 = liv.evaluate(ev(candidates=[C(11, "absent")], jsonl_grew=False, claim_read=cr))
    check(v2.state == "dead",
          "a claim must not mask a session lane's death; got %s/%s" % (v2.state, v2.reason))
    # (c) `dead` needs a NON-EMPTY candidate set — the vacuity guard (C4) is what
    #     makes a claim-shaped Evidence structurally unable to read dead.
    check(liv.is_dead_evidence([]) is False, "the C4 vacuity guard is load-bearing")
    v3 = liv.evaluate(_claim_ev(candidates=[], jsonl_grew=False, claim_read=cr))
    check(v3.state == "unknown", "a claim-shaped Evidence never reads dead; got %s" % v3.state)


@test("T30 the claim logic is INERT when claim_read is None — existing verdicts unchanged (#1777)")
def t30_claim_logic_inert_without_claim_read():
    # (state, reason, evidence) — the reason is pinned too, because a mutation that
    # silently swaps the ABSTENTION REASON changes what the operator reads.
    cases = (
        ("dead", "incarnations-absent",
         ev(candidates=[C(11, "absent")], jsonl_grew=False, jsonl_age_ms=H)),
        ("unknown", "no-holder-record", ev(candidates=[])),
        ("running-quiet", "jsonl-grew", ev(candidates=[C(11, "holder")], jsonl_grew=True)),
        ("idle", "jsonl-old", ev(candidates=[C(11, "holder")], jsonl_age_ms=25 * H)),
        ("unknown", "ps-unreadable", ev(candidates=[], ps_ok=False)),
        ("unknown", "store-unreadable", ev(candidates=[], store_ok=False)),
        ("unknown", "off-fence", ev(candidates=[C(11, "off-fence")])),
    )
    for want_state, want_reason, e in cases:
        check(e.claim_read is None, "the fixture must exercise the inert path")
        v = liv.evaluate(e)
        check((v.state, v.reason) == (want_state, want_reason),
              "claim logic must be inert for a session caller (want %s/%s, got %s/%s)"
              % (want_state, want_reason, v.state, v.reason))
    check(hasattr(liv, "claim_verdict") and hasattr(liv, "ClaimRead"),
          "the claim vocabulary exists but is reachable only via claim_read")


@test("T31 the mutation harness cannot read a NON-RUNNING test as 'caught' (#1777)")
def t31_mutation_verdict_requires_a_real_failure():
    """Pinned by a direct truth-table assertion, not a paired mutation.

    A mutation is caught only when the paired test RAN and FAILED. The pre-fix
    harness used `returncode != 0`, and `run_tests` ALSO returns 1 when the filter
    matched nothing (``PASS=0 FAIL=0``) — so a renamed test id, or a typo in the
    map, reported every mutation CAUGHT while verifying nothing: a false-PASS
    generator inside the very evidence the suite's mutation claims rest on. The
    decision lives in THIS file, which the harness never mutates, so it is pinned
    where it lives (the same truth table is pinned in `claim_lanes.test.py` L23).
    """
    caught = _mutation_verdict
    check(caught(0, "PASS=1 FAIL=0") is False, "a green run is not a caught mutation")
    check(caught(1, "PASS=0 FAIL=1") is True, "a failed paired test IS caught")
    check(caught(1, "PASS=0 FAIL=0") is False,
          "a filter that matched NO test is not a caught mutation")
    check(caught(1, "  ok   T1 x\nPASS=1 FAIL=0\n") is False, "same, with noise around it")
    check(caught(1, "FAIL T1 x\nPASS=0 FAIL=2\n") is True, "more than one failure counts")
    check(caught(1, "") is False, "an unparseable run is not a caught mutation")


# ══════════════════════════════════════════════════════════════════════════
# The mutation map: each entry reintroduces the defect its test catches.
# ══════════════════════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════════════
# T21 — #5389 (a): the in-flight tool is read from the lane's OWN transcript.
# `docs/ops/fleet-liveness.md` §5 item 2 measured that NO store record carries
# `toolsInFlight`, so `ev.tool` was always None and the veto never fired. The
# fixtures below use pi's REAL entry shape — `timestamp` at the ENTRY level,
# `message` nested — because a shape the parser cannot read is exactly how a
# check silently never matches.
# ═══════════════════════════════════════════════════════════════════
@test("T21 the in-flight tool is derived from the lane's own transcript (#5389 a)")
def t21_tool_from_jsonl():
    d = tempfile.mkdtemp(prefix="liv-jsonl-")
    try:
        path = os.path.join(d, "session.jsonl")

        def real(role, ts_ms, **msg):
            base = {"role": role}
            base.update(msg)
            return {"type": "message", "id": "e", "parentId": None,
                    "timestamp": _iso(ts_ms), "message": base}

        def write(entries):
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("\n".join(json.dumps(e) for e in entries) + "\n")

        started = NOW_MS - 21 * M  # frozen 21 min: past S=20min, inside 4h

        # (a) the tail is an assistant message carrying a call with no result
        #     — a tool IS in flight, and its age is the CALL's age.
        write([
            real("user", started - 60_000, content=[{"type": "text", "text": "go"}]),
            real("assistant", started, stopReason="toolUse",
                 content=[{"type": "toolCall", "name": "bash", "id": "call_A"}]),
        ])
        t = liv.tool_from_jsonl(path, NOW_MS, silence_age_ms=21 * M)
        check(t is not None and t.tools_in_flight == 1, "one call in flight; got %s" % t)
        check(t.name == "bash", "the in-flight call's name; got %r" % t.name)
        check(t.tool_age_ms == 21 * M, "the age is the CALL's age; got %s" % t.tool_age_ms)
        check(t.tool_updates is False and t.cpu_advanced is False and t.cpu_stall_ms == 0,
              "the two underivable fields stay at the FAIL-CLOSED default; got %s" % t)

        # (b) an answered call is not in flight.
        write([
            real("assistant", started, stopReason="toolUse",
                 content=[{"type": "toolCall", "name": "bash", "id": "call_A"}]),
            real("toolResult", started + 1000, toolName="bash", toolCallId="call_A",
                 content=[{"type": "text", "text": "done"}]),
        ])
        check(liv.tool_from_jsonl(path, NOW_MS) is None,
              "a matching toolResult means nothing is in flight")

        # (c) a call the stop reason DISCARDS is not in flight either — the veto
        #     and the turn boundary must not disagree about openness.
        write([real("assistant", started, stopReason="error",
                    content=[{"type": "toolCall", "name": "bash", "id": "call_A"}])])
        check(liv.tool_from_jsonl(path, NOW_MS) is None,
              "`error` discards its calls (CALL_DISCARDING_STOP_REASONS)")

        # (d) a compaction trailer abstains, exactly as the turn boundary does.
        write([
            real("assistant", started, stopReason="toolUse",
                 content=[{"type": "toolCall", "name": "bash", "id": "call_A"}]),
            {"type": "compaction", "summary": "…"},
        ])
        check(liv.tool_from_jsonl(path, NOW_MS) is None,
              "a compaction trailer decides nothing, so no tool is asserted")

        # (e) an UNREADABLE entry timestamp must NOT leave the age UNKNOWN.
        #     An unknown age never expires (`_exceeds(None, ...)` is False) and a
        #     derived tool can reach ONLY the age backstop — so `None` would make
        #     the veto PERMANENT: the lane would read `running-quiet/tool-in-flight`
        #     forever and `idle` would become unreachable (T9: the veto must never
        #     be forever). The fallback is the transcript's OWN mtime, which is a
        #     real measurement and still grows while the file is frozen.
        write([{"type": "message", "id": "e", "message": {
            "role": "assistant", "stopReason": "toolUse",
            "content": [{"type": "toolCall", "name": "bash", "id": "call_A"}]}}])
        os.utime(path, ((NOW_MS - 26 * M) / 1000.0,) * 2)
        unaged = liv.tool_from_jsonl(path, NOW_MS)
        check(unaged is not None and unaged.tool_age_ms is not None,
              "an undated call must fall back to the transcript's age, never None")
        check(abs(unaged.tool_age_ms - 26 * M) <= 2000,
              "the fallback is the transcript's own mtime age; got %s" % unaged.tool_age_ms)
        check(liv.tool_veto_expired(unaged) is False,
              "26min is inside the 4h backstop, so the veto still holds")
        check(liv.tool_veto_expired(dataclasses.replace(unaged, tool_age_ms=5 * H)) is True,
              "and past the 4h backstop it EXPIRES — the veto is BOUNDED (T9)")

        # (g) cycle-3: if the call cannot be dated from ANY source (the entry
        #     stamp is absent AND the file cannot be stat'd) then NO Tool is
        #     asserted. A Tool with an unmeasurable age would make the veto
        #     permanent (`_exceeds(None, bound)` is False) \u2014 the one outcome
        #     T9 forbids \u2014 and the honest reading is the module's own
        #     `jsonl-age-unknown` abstention, never a phantom veto.
        write([{"type": "message", "id": "e", "message": {
            "role": "assistant", "stopReason": "toolUse",
            "content": [{"type": "toolCall", "name": "bash", "id": "call_A"}]}}])
        real_stat = os.stat
        attempts = []

        def flaky(target, *a, **k):
            attempts.append(target)
            if len(attempts) > 1:      # let _last_message_entry read; fail the fallback
                raise OSError("simulated stat failure")
            return real_stat(target, *a, **k)

        try:
            os.stat = flaky
            undatable = liv.tool_from_jsonl(path, NOW_MS)
        finally:
            os.stat = real_stat
        check(len(attempts) >= 2,
              "the fixture must actually reach the mtime fallback; got %d stat(s)" % len(attempts))
        check(undatable is None,
              "an undateable call must assert NO veto (an unmeasurable age would be FOREVER)")

        # (h) #5389 review F2: a FUTURE-dated entry stamp must not pin the age at
        #     0 forever. A writer host with a wrong clock (a VM booting on a bad
        #     RTC before NTP corrects it) stamps the entry ahead of the
        #     classifier's clock; a bare `now - started` clamps to 0 and STAYS 0,
        #     so the 4h AGE backstop is never reached and the veto is PERMANENT —
        #     `idle` becomes unreachable (T9: never forever). The transcript's own
        #     mtime is a genuine LOWER bound on the call's age (the file is written
        #     at or after the call), so it bounds the age from the other side too.
        write([real("assistant", NOW_MS + 10 * H, stopReason="toolUse",
                    content=[{"type": "toolCall", "name": "bash", "id": "call_A"}])])
        os.utime(path, ((NOW_MS - 5 * H) / 1000.0,) * 2)
        future = liv.tool_from_jsonl(path, NOW_MS)
        check(future is not None and future.tool_age_ms is not None,
              "a future-stamped in-flight call is still a tool")
        check(future.tool_age_ms >= 5 * H - 2000,
              "a future stamp is bounded by the transcript's own mtime, never 0; got %s"
              % future.tool_age_ms)
        check(liv.tool_veto_expired(future) is True,
              "and past the 4h backstop it EXPIRES — a future stamp is not a permanent veto (T9)")

        # (f) no file / an empty file is an ABSTENTION, never a tool.
        check(liv.tool_from_jsonl(None, NOW_MS) is None, "no path -> no assertion")
        check(liv.tool_from_jsonl(os.path.join(d, "absent.jsonl"), NOW_MS) is None,
              "a missing transcript -> no assertion")
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ═══════════════════════════════════════════════════════════════════
# T22 — #5389 (b)/(c) on the FLEET side: the veto mirrors the watchdog's new
# rule. CPU is a SPARE signal: `progressing` SUPPRESSES the expiry, and an
# `unknown` channel may not expire it either — it falls to the AGE backstop, so
# the veto is slower but never forever (T9's own law).
# ═══════════════════════════════════════════════════════════════════
@test("T22 the veto requires no-progress evidence; progressing suppresses; unknown falls to the age backstop (#5389 b/c)")
def t22_in_flight_progress_mirror():
    def tool(**kw):
        base = dict(tools_in_flight=1, tool_updates=True)
        base.update(kw)
        return liv.Tool(**base)

    # The sentinel trap, pinned FIRST: `cpu_stall_ms=0` with the latch ARMED is
    # the strongest progress evidence there is (advanced on this very tick),
    # never "unknown". The measured #5387 cut had exactly this shape.
    check(liv.in_flight_progress(tool(cpu_advanced=True, cpu_stall_ms=0)) == "progressing",
          "armed latch + cpu_stall_ms=0 is PROGRESSING, not unknown")
    check(liv.in_flight_progress(tool(cpu_advanced=False, cpu_stall_ms=0)) == "unknown",
          "an unarmed latch is the not-probed sentinel -> unknown")
    check(liv.in_flight_progress(tool(cpu_advanced=True, cpu_stall_ms=31 * M)) == "no-progress",
          "demonstrated work then flat past C=30min -> no-progress")
    check(liv.in_flight_progress(tool(cpu_advanced=True, cpu_stall_ms=29 * M)) == "progressing",
          "flat under C is still progressing")
    # TASK_CPU_STALL_MS=0 disables the channel; the operator did not thereby
    # authorise a cut on it.
    check(liv.in_flight_progress(tool(cpu_advanced=True, cpu_stall_ms=99 * M), 0) == "unknown",
          "a disabled CPU bound reads unknown, never no-progress")
    check(liv.in_flight_progress(tool(cpu_advanced=True, cpu_stall_ms=None)) == "unknown",
          "an unmeasured stall is unknown")

    # (b) silence past S with PROGRESS -> the veto HOLDS (was: expired -> wedged).
    check(liv.tool_veto_expired(tool(cpu_advanced=True, cpu_stall_ms=0,
                                     silence_age_ms=60 * M, tool_age_ms=60 * M)) is False,
          "tool-silence must not expire on a PROGRESSING tool")
    # ...but progress is a reprieve from S, NEVER an exemption from the age
    # backstop: the watchdog's `tool-stall` clause has no CPU conjunct, so it
    # cuts a tool whose CPU is still advancing once the backstop is passed.
    check(liv.tool_veto_expired(tool(cpu_advanced=True, cpu_stall_ms=0,
                                     silence_age_ms=5 * H, tool_age_ms=5 * H)) is True,
          "a PROGRESSING tool is still bounded at the 4h age backstop")
    # silence past S with demonstrated-then-flat CPU -> the watchdog WOULD cut.
    check(liv.tool_veto_expired(tool(cpu_advanced=True, cpu_stall_ms=31 * M,
                                     silence_age_ms=21 * M, tool_age_ms=31 * M)) is True,
          "no-progress past S expires the veto")
    # (c) unknown does NOT expire on S — but it is not forever either.
    check(liv.tool_veto_expired(tool(cpu_advanced=False, silence_age_ms=21 * M,
                                     tool_age_ms=21 * M, turn_active=True)) is False,
          "an unreadable CPU channel may not expire the veto at S")
    check(liv.tool_veto_expired(tool(cpu_advanced=False, silence_age_ms=5 * H,
                                     tool_age_ms=5 * H, turn_active=True)) is True,
          "...but the 4h AGE backstop still bounds it — never forever")

    # F1 (#5389 review, cycle 2): a clause that does NOT fire must fall through
    # to the backstop. A no-progress tool whose silence is still inside S used to
    # hold the veto open at ANY age; the watchdog cuts it at the progress-blind
    # `tool-stall` backstop, so the classifier must too (T9: never forever).
    check(liv.tool_veto_expired(tool(cpu_advanced=True, cpu_stall_ms=31 * M,
                                     silence_age_ms=19 * M, tool_age_ms=5 * H)) is True,
          "a no-progress tool inside S is still bounded by the age backstop")
    check(liv.tool_veto_expired(tool(cpu_advanced=True, cpu_stall_ms=31 * M,
                                     silence_age_ms=None, tool_age_ms=5 * H)) is True,
          "an OMITTED streamAgeMs must not hold the veto open forever either")

    # End-to-end: the SAME evidence reads running-quiet with the fix.
    v = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=60 * M, jsonl_turn=OPEN_TURN,
                        tool=tool(cpu_advanced=True, cpu_stall_ms=0,
                                  silence_age_ms=60 * M, tool_age_ms=60 * M)))
    check(v.state == "running-quiet" and v.reason == "tool-in-flight",
          "a progressing tool keeps the lane off `wedged`; got %s/%s" % (v.state, v.reason))


# ═══════════════════════════════════════════════════════════════════
# T23 — the measured #5387 false cut, reproduced end to end and hermetic:
# a fenced holder, a transcript frozen 21 min, the tail carrying an unanswered
# `bash`. `gather` must derive the tool from that transcript and the lane must
# read `running-quiet/tool-in-flight` — NOT `wedged/turn-open:pending-tool-call`.
# The control (the same evidence with `tool=None`, i.e. today's wiring) is
# asserted too, so the test proves the veto is LOAD-BEARING and not vacuous.
# ═══════════════════════════════════════════════════════════════════
@test("T23 the #5387 false cut: an unanswered transcript call keeps the lane off `wedged` (#5389 a+b)")
def t23_false_cut_reproduced():
    d = tempfile.mkdtemp(prefix="liv-jsonl-")
    try:
        frozen = NOW_MS - 21 * M
        sessions = os.path.join(d, "sessions")
        os.makedirs(os.path.join(sessions, "--x--"))
        sfile = os.path.join(sessions, "--x--", "2026-01-01T00-00-00-000Z_sid-1.jsonl")
        entries = [
            {"type": "message", "id": "a", "timestamp": _iso(frozen - 60_000),
             "message": {"role": "user", "content": [{"type": "text", "text": "grep"}]}},
            # The measured shape: an in-flight `bash` that has streamed and then
            # gone quiet, with the turn still OPEN (no toolResult after it).
            {"type": "message", "id": "b", "timestamp": _iso(frozen),
             "message": {"role": "assistant", "stopReason": "toolUse",
                         "content": [{"type": "toolCall", "name": "bash", "id": "call_A"}]}},
        ]
        with open(sfile, "w", encoding="utf-8") as fh:
            fh.write("\n".join(json.dumps(e) for e in entries) + "\n")
        os.utime(sfile, (frozen / 1000.0, frozen / 1000.0))

        payload = {"sessions": {"sid-1": {"pid": 555, "pidStartSeconds": PROBE_EPOCH,
                                           "cwd": "/x", "agentLifecycle": "idle",
                                           "runtimeStatus": "idle"}}}
        with temp_store(payload) as (store, _sd):
            with ps_env([ps_row(555)]):
                e = liv.gather("sid-1", store_path=store, sessions_dir=sessions, now_ms=NOW_MS)

        check(e.tool is not None and e.tool.tools_in_flight == 1,
              "gather must derive the in-flight tool from the transcript; got %s" % e.tool)
        check(e.jsonl_turn is not None and e.jsonl_turn.stalled is True,
              "the tail is a positively OPEN turn; got %s" % e.jsonl_turn)
        check(e.jsonl_age_ms > liv.STREAM_STALL_MS, "the fixture is frozen past S")

        v = liv.evaluate(e)
        check(v.state == "running-quiet" and v.reason == "tool-in-flight",
              "a lane inside one long read is quiet, never wedged; got %s/%s" % (v.state, v.reason))
        # The row must name the UNWRITTEN call the veto holds on — the same
        # evidence the `wedged` row renders — or the report cannot say which
        # step it is waiting for (#5389 review cycle 1 P1).
        check("call_A" in v.detail,
              "the tool-in-flight verdict names the in-flight call; got %r" % v.detail)

        # THE CONTROL: strip the derived tool (today's wiring, 0 of 1011 records)
        # and the same evidence reads `wedged`. Without this the test could pass
        # on a lane that was never wedged-shaped to begin with.
        v_no_tool = liv.evaluate(dataclasses.replace(e, tool=None))
        check(v_no_tool.state == "wedged",
              "control: with NO tool the same evidence IS wedged; got %s/%s"
              % (v_no_tool.state, v_no_tool.reason))
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ═══════════════════════════════════════════════════════════════════
# T24 — #5389 review (cycle 4, P2). A `length`-truncated assistant message
# carrying tool calls is an OPEN turn whose calls pi has ALREADY FAILED
# (`failToolCallsFromTruncatedMessage`; all 78 measured results after a
# `length`+calls message carry `isError: true`, "Tool call ... was not
# executed"). OPEN and IN FLIGHT are different conditions for this shape: the
# turn is open, but no tool is running. The transcript-derived veto must not
# manufacture one from the truncated message, or the lane stands quiet
# (`running-quiet/tool-in-flight`, held to the 4 h age backstop) where the
# watchdog's zero-tool `stream-stall` cut at S = 20 min — the fail-open
# divergence `docs/ops/fleet-liveness.md` §6 forbids. T18 pins the OPEN half;
# this pins the veto half, so the two can never be conflated again.
# ═══════════════════════════════════════════════════════════════════
@test("T24 a `length`-truncated call is OPEN but NOT in flight: no phantom tool veto (#5389 P2)")
def t24_length_truncated_call_is_not_a_tool():
    d = tempfile.mkdtemp(prefix="liv-length-")
    try:
        path = os.path.join(d, "session.jsonl")
        frozen = NOW_MS - 21 * M  # past S=20min, inside the 4h backstop

        def real(role, ts_ms, **msg):
            base = {"role": role}
            base.update(msg)
            return {"type": "message", "id": "e", "parentId": None,
                    "timestamp": _iso(ts_ms), "message": base}

        # pi's `length` truncation FAILS the message's calls; the turn continues.
        write_entries = [real("assistant", frozen, stopReason="length",
                             content=[{"type": "toolCall", "name": "bash",
                                       "id": "call_LEN"}])]
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(json.dumps(e) for e in write_entries) + "\n")
        os.utime(path, (frozen / 1000.0, frozen / 1000.0))

        # (a) The turn boundary still reads OPEN, exactly as T18 pins it.
        turn = liv.turn_from_jsonl(path)
        check(turn is not None and turn.stalled is True
              and turn.reason == "turn-open:pending-tool-call",
              "a `length`+calls turn is still OPEN; got %s" % turn)

        # (b) ... but NO tool is in flight: pi failed the calls, so the veto
        #     abstains rather than manufacturing a tool from the truncation.
        check(liv.tool_from_jsonl(path, NOW_MS, silence_age_ms=21 * M) is None,
              "a `length`-FAILED call is not an in-flight tool; the veto must not "
              "manufacture one from a truncated message")

        # (c) End to end: a frozen, fenced, OPEN length-truncated lane is WEDGED
        #     at S (the watchdog's zero-tool `stream-stall`), never held quiet to
        #     the 4h backstop by a phantom veto.
        tool = liv.tool_from_jsonl(path, NOW_MS, silence_age_ms=21 * M)
        e = ev(candidates=[C(1, "holder")], jsonl_age_ms=21 * M, jsonl_turn=turn,
               tool=tool)
        v = liv.evaluate(e)
        check(v.state == "wedged" and v.reason == "turn-open:pending-tool-call",
              "a phantom veto must not suppress the honest `wedged` verdict; got %s/%s"
              % (v.state, v.reason))
        check("call_LEN" in v.detail,
              "the wedged row names the open (failed) call; got %r" % v.detail)

        # (d) The sibling case is unchanged: `toolUse` IS in flight (T23's
        #     shape), so this test cannot pass by disabling the derivation.
        write_entries = [real("assistant", frozen, stopReason="toolUse",
                             content=[{"type": "toolCall", "name": "bash",
                                       "id": "call_FLY"}])]
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(json.dumps(e) for e in write_entries) + "\n")
        os.utime(path, (frozen / 1000.0, frozen / 1000.0))
        flying = liv.tool_from_jsonl(path, NOW_MS, silence_age_ms=21 * M)
        check(flying is not None and flying.tools_in_flight == 1,
              "a `toolUse` call is still derived as in flight; got %s" % flying)
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ══════════════════════════════════════════════════════════════════════════
# THE LOG-LANE AXIS (T32–T51) — a lane that writes a log and no transcript
# ══════════════════════════════════════════════════════════════════════════
# 20 tests, in the same groups the §13 regression contract states (keep the two
# in step — a banner naming only T32–T38 told a reader the axis was 7 tests and
# left T43–T51 covered by nothing the owning section named):
#   T32–T38 VERDICT · T39–T42 ACQUISITION · T43–T44 BINDING · T45–T46 drop-reason
#   + census binding · T47–T49 broken readings + fact-naming · T50 the
#   abstention-masking refusal · T51 the `/proc` reader's own abstention.
#
# These are the MUTATION tests the 2026-11-03 measurement demands. Each one is
# stated so that it FAILS against the pre-fix behaviour (for the VERDICT group
# that behaviour is a reader keyed on the log's mtime, with one state for "not
# growing"): the paired Mutation below re-introduces exactly that behaviour and
# the suite reports the test RED.
def LR(**kw):
    base = dict(readable=True, present=True, path="/tmp/L-x.log")
    base.update(kw)
    return liv.LogRead(**base)


@test("T32 a static LOG + a growing TRANSCRIPT reads `working` — log mtime is not liveness")
def t32():
    # The `pi -p` shape: the log froze 40 minutes ago while the lane works hard.
    # mtime alone says "dead". The transcript's growth says "working".
    v = liv.log_lane_verdict(LR(size_delta=0, transcript_grew=True, cpu_delta_cs=0,
                                alive=True, age_ms=40 * M))
    check(v.state == "working",
          "a static log with a growing transcript is WORKING; got %s/%s" % (v.state, v.reason))
    check(v.reason == "progress:transcript", "the reason names the signal; got %r" % v.reason)

    # …and the `pi -p --no-session` shape, which has NO transcript at all: the
    # CPU delta on the lane's process tree is the signal that survives a silent
    # tool call. 154 CPU-seconds burned = tortoise #5387's measured lane.
    v2 = liv.log_lane_verdict(LR(size_delta=0, transcript_grew=None, cpu_delta_cs=15_400,
                                 alive=True, age_ms=3 * H))
    check(v2.state == "working" and v2.reason == "progress:cpu",
          "a CPU-advancing lane with a byte-identical log is WORKING; got %s/%s"
          % (v2.state, v2.reason))


@test("T33 a lane whose process EXITED with no verdict is `no-verdict`, never `frozen`")
def t33():
    for age in (10 * M, 3 * H, 30 * H):
        v = liv.log_lane_verdict(LR(alive=False, verdict="", size_delta=0,
                                    transcript_grew=False, cpu_delta_cs=0, age_ms=age))
        check(v.state == "no-verdict",
              "an exited process that told us nothing reads `no-verdict`, got %s (age %d)"
              % (v.state, age))
        check(v.state != "frozen", "an exited process is TERMINAL, never frozen")
        check("the process ended and told us nothing" in v.detail,
              "the detail says what happened; got %r" % v.detail)
    # And it is the SAME answer through the dispatcher a consumer calls.
    v = liv.evaluate(liv.Evidence(log_read=LR(alive=False, verdict="")))
    check(v.state == "no-verdict", "evaluate() reaches the log axis; got %s" % v.state)


@test("T34 static log + static transcript + zero CPU delta for the WINDOW reads `frozen`")
def t34():
    v = liv.log_lane_verdict(LR(alive=True, size_delta=0, transcript_grew=False,
                                cpu_delta_cs=0, age_ms=liv.LOG_FREEZE_MS + M))
    check(v.state == "frozen", "both signals flat past the window is frozen; got %s/%s"
          % (v.state, v.reason))
    check("freeze_ms=%d" % liv.LOG_FREEZE_MS in v.detail,
          "frozen STATES its inactivity window; got %r" % v.detail)
    check("window_ms=%d" % liv.LOG_WINDOW_MS in v.detail,
          "…and names the SAMPLE window separately, so a reader can tell them apart; got %r"
          % v.detail)
    # A sub-tolerance CPU twitch is NOT progress (the stated tolerance does work).
    v2 = liv.log_lane_verdict(LR(alive=True, size_delta=0, transcript_grew=False,
                                 cpu_delta_cs=liv.LOG_CPU_TOL_CS, age_ms=liv.LOG_FREEZE_MS + M))
    check(v2.state == "frozen", "a delta at the tolerance is NOT progress; got %s" % v2.state)
    # …and INSIDE the window a flat stretch is the fleet's normal resting state.
    v3 = liv.log_lane_verdict(LR(alive=True, size_delta=0, transcript_grew=False,
                                 cpu_delta_cs=0, age_ms=liv.LOG_FREEZE_MS - M))
    check(v3.state == "working" and v3.reason == "within-window",
          "flat but inside the window is not frozen; got %s/%s" % (v3.state, v3.reason))


@test("T35 a lane with NO log and NO transcript is the ABSTENTION, never `dead`")
def t35():
    v = liv.log_lane_verdict(liv.LogRead(readable=False, present=False, path=""))
    check(v.state == "unknown", "an absent log is an abstention; got %s/%s" % (v.state, v.reason))
    check(v.state != "dead" and v.state != "no-verdict",
          "an absence is NOT a death witness (the `no-log-evidence` refusal)")
    check(v.reason == "log-unreadable", "the reason is named; got %r" % v.reason)
    # A lane whose signals could not be READ abstains too — never "flat".
    v2 = liv.log_lane_verdict(LR(alive=True, size_delta=None, transcript_grew=None,
                                 cpu_unreadable=True, age_ms=3 * H))
    check(v2.state == "unknown" and v2.reason == "no-progress-signal-readable",
          "an unreadable signal must never convict; got %s/%s" % (v2.state, v2.reason))
    # ⛔ AND ONE UNREADABLE SIGNAL IS ENOUGH (the `or` conjunct). With `and` this case
    # fell through to `frozen`: a readable-but-flat log plus an unreadable CPU channel
    # is EXACTLY the shape of a lane working through a long silent tool call, so the
    # conjunction would have rebuilt the log-mtime defect inside the fix.
    v3 = liv.log_lane_verdict(LR(alive=True, size_delta=0, transcript_grew=False,
                                 cpu_unreadable=True, cpu_delta_cs=None,
                                 age_ms=liv.LOG_FREEZE_MS + H))
    check(v3.state == "unknown",
          "a flat log with an UNREAD CPU channel is an abstention, never frozen; got %s"
          % v3.state)
    v4 = liv.log_lane_verdict(LR(alive=True, size_delta=None, transcript_grew=True,
                                 cpu_delta_cs=0, age_ms=liv.LOG_FREEZE_MS + H))
    check(v4.state == "working",
          "a growing transcript with an unread log delta is still WORKING (progress is "
          "a veto, not a conjunction); got %s" % v4.state)
    # ⛔ A NEGATIVE DELTA IS A BROKEN READING, NOT A FLAT ONE. A stable subtree cannot
    # LOSE CPU, so a negative delta means one of the two reads was incomplete — the
    # same rule `lane-reap.sh` states for its own two-sample CPU gate. Read as "flat",
    # it froze a lane that may be working (measured with real `ps`: a silent tool loop
    # spawning short-lived CPU children read -200 cs on 2 of 5 trials).
    v5 = liv.log_lane_verdict(LR(alive=True, size_delta=0, transcript_grew=False,
                                 cpu_delta_cs=-200, age_ms=liv.LOG_FREEZE_MS + H))
    check(v5.state == "unknown" and v5.reason == "no-progress-signal-readable",
          "a negative CPU delta abstains, never freezes; got %s/%s" % (v5.state, v5.reason))


@test("T36 the log axis is INERT for session queries, and cannot mask session evidence (#1777 B7)")
def t36():
    # (a) INERT: with no log_read the ladder answers exactly as it always has.
    base = ev(jsonl_grew=False, jsonl_age_ms=H, candidates=[])
    check(liv.evaluate(base).reason == "no-holder-record",
          "the session ladder is untouched when log_read is None")
    check(liv.evaluate(ev(log_read=None, candidates=[])).reason == "no-holder-record",
          "an explicit None is the same as an absent field")
    # (b) B7: BOTH kinds of evidence in one query is REFUSED by name, not resolved
    # by whichever axis happens to be checked first.
    v = liv.evaluate(ev(log_read=LR(alive=False, verdict="finished")))
    check(v.state == "unknown" and v.reason == "log-read-on-session-query",
          "a log read on a session query is refused by name; got %s/%s" % (v.state, v.reason))


@test("T37 the bound's verdict is PARSED, and only a verdict WITH A CLEAN rc means finished")
def t37():
    line = ("[lane-bound] VERDICT verdict=finished tag=lane pid=42 rc=0 elapsed=612s "
            "wall_bound=3300s idle_bound=1200s silent=3s bytes=9124 bytes_delta=0 "
            "cpu_cs=15400 cpu_delta_cs=1200 tol_cs=10 cpu_unreadable=0 signal=none log=/tmp/L-x.log")
    check(liv.parse_bound_verdict(line) == "finished", "the real line parses")
    check(liv.parse_bound_line(line) == ("finished", "0"),
          "the rc travels with the verdict; got %r" % (liv.parse_bound_line(line),))
    check(liv.parse_bound_verdict("nothing here") == "", "no line is NO verdict, not some verdict")
    check(liv.parse_bound_verdict("[lane-bound] VERDICT verdict=invented-later rc=0") == "",
          "an unrecognised verdict token is NOT adopted (it would decide an unmodelled state)")
    check(liv.parse_bound_verdict("".join([line, "\n"]) + line) == "finished",
          "the LAST line wins (one status line, but a re-run may append)")
    # ⛔ THE LAST LINE WINS EVEN WHEN ITS TOKEN IS UNRECOGNISED. Keeping the last
    # RECOGNISED verdict adopts a STALE one: `…finished…` then `…needs-review…` read as
    # `finished` — the false-PASS class this axis exists to remove.
    check(liv.parse_bound_line(line + "\n[lane-bound] VERDICT verdict=needs-review tag=t rc=0\n")
          == ("", None),
          "an unrecognised FINAL token is no-verdict, never the previous verdict")
    # ⛔ …AND THE *LINE* MUST BE LOCATED, NOT THE TOKEN. A final marker whose token the
    # token regex cannot match (uppercase, absent, or spaced) is still the FINAL LINE, so
    # it must yield NO VERDICT — not silently promote the previous `finished`. Measured
    # before this fix: all three cases below returned ('finished', '0').
    for final in ("[lane-bound] VERDICT verdict=FINISHED tag=t pid=7 rc=0",
                  "[lane-bound] VERDICT tag=t pid=7 rc=0",
                  "[lane-bound] VERDICT verdict = stalled tag=t pid=7 rc=0"):
        check(liv.parse_bound_line(line + "\n" + final + "\n") == ("", None),
              "an unmatchable FINAL marker is no-verdict, never the previous one: %r" % final)
        # …and the pid is read off that SAME final line, so the two parsers cannot
        # disagree about which line is "the line" (they did while each kept its own
        # last-MATCH loop).
        check(liv.parse_bound_pid(line + "\n" + final + "\n") == "7",
              "the pid comes from the FINAL line, not the earlier one: %r" % final)
    # ⛔ `rc=` is the LAST one on the line: a non-greedy match took the first, so an
    # earlier `tag=rc=7` made a completed lane read `no-verdict`.
    check(liv.parse_bound_line("[lane-bound] VERDICT verdict=finished tag=rc=7 pid=42 rc=0\n")
          == ("finished", "0"),
          "the real rc= wins over an earlier rc=-shaped field")

    # ⛔ `verdict=finished` IS NOT "the turn completed". `lane-bound.sh` writes it
    # whenever NO BOUND FIRED and puts the child's real status in `rc=` on the same
    # line — MEASURED: `lane-bound.sh run --log L -- sh -c 'exit 7'` emits
    # `verdict=finished … rc=7`. Reading that as `finished` is a false PASS over lost
    # work: nobody re-dispatches it.
    v = liv.log_lane_verdict(LR(alive=False, verdict="finished", rc="7"))
    check(v.state == "no-verdict", "a crashed lane under verdict=finished is NOT finished; got %s"
          % v.state)
    check(v.reason == "bound-finished-rc:7", "the rc is named; got %r" % v.reason)
    # `na` is `watch` mode's UNCONDITIONAL shape (`lane-bound.sh:397`), and `watch` is
    # the mode `spawn-gate.sh`'s `run_agent` uses for EVERY lane/fixer/worker
    # (`:1532`). `run` mode — the only one that puts the child's real status on the
    # bound line — is never used by the fleet. So `rc=na` carries NO completion fact:
    # a lane that COMPLETED and a lane that CRASHED / was OOM-killed / was killed by
    # the completion watchdog write the identical `verdict=finished rc=na`. Accepting
    # `na` on its own made the rc conjunct INERT for the whole production population.
    # It must be CORROBORATED by the launcher's own `[timeout] agent … rc=` line.
    v = liv.log_lane_verdict(LR(alive=False, verdict="finished", rc="na"))
    check(v.state == "unknown" and v.reason == "finished-rc-uncorroborated",
          "`rc=na` alone is NOT completion evidence; got %s/%s" % (v.state, v.reason))
    v = liv.log_lane_verdict(LR(alive=False, verdict="finished", rc="na", runner_rc="0"))
    check(v.state == "finished", "`rc=na` corroborated by a launcher rc=0 is finished; got %s"
          % v.state)
    for bad_rc in ("7", "137", "1"):
        v = liv.log_lane_verdict(LR(alive=False, verdict="finished", rc="na", runner_rc=bad_rc))
        check(v.state == "no-verdict",
              "`rc=na` + a launcher rc=%s is NOT finished; got %s" % (bad_rc, v.state))
        check(v.reason == "bound-finished-runner-rc:%s" % bad_rc,
              "the launcher's rc is named; got %r" % v.reason)
    # ⛔ THE LAUNCHER LINE IS PARSED LAST-WINS, and its pid is what binds it to an
    # incarnation (an earlier dispatch's `[timeout]` line is still in the same log).
    check(liv.parse_runner_line(
        "[timeout] agent pid=4242 wall_limit=3300s elapsed=9s rc=7\n"
        "[timeout] agent pid=4242 wall_limit=3300s elapsed=99s rc=0") == ("4242", "0"),
          "the LAST launcher rc= wins")
    check(liv.parse_runner_line("no launcher line here") == ("", None),
          "no launcher line is no witness, never rc=0")
    # An rc that cannot be read is an ABSTENTION, never an assumed success.
    v = liv.log_lane_verdict(LR(alive=False, verdict="finished", rc=None))
    check(v.state == "unknown" and v.reason == "finished-rc-unreadable",
          "a verdict without a readable rc abstains; got %s/%s" % (v.state, v.reason))

    # A bound KILL is real death (mechanism 3), and it must not read `finished`.
    for killed in ("stalled", "exceeded-wallclock"):
        v = liv.log_lane_verdict(LR(alive=False, verdict=killed, rc="143"))
        check(v.state == "dead",
              "verdict=%s is real death, not a finish; got %s" % (killed, v.state))
        check(v.reason == "bound-verdict:%s" % killed, "the verdict is named; got %r" % v.reason)
    v = liv.log_lane_verdict(LR(alive=False, verdict="finished", rc="0"))
    check(v.state == "finished" and v.reason == "bound-verdict:finished",
          "verdict=finished with rc=0 is `finished`; got %s/%s" % (v.state, v.reason))

    # ⛔ A RECOGNISED VERDICT WITH NO `rc=` ABSTAINS (it must reach
    # `finished-rc-unreadable`), it must NOT be swallowed into "no verdict".
    check(liv.parse_bound_line("[lane-bound] VERDICT verdict=finished tag=t pid=1 elapsed=5s")
          == ("finished", None), "a recognised verdict with no rc= keeps its token")
    check(liv.log_lane_verdict(LR(alive=False, verdict="finished", rc=None)).reason
          == "finished-rc-unreadable", "…and abstains rather than guessing")
    # ⛔ an `rc=` in a LATER field must not supply the exit status
    check(liv.parse_bound_line(
        "[lane-bound] VERDICT verdict=finished tag=t pid=1 rc=0 log=/tmp/L-rc=5.log")
        == ("finished", "0"), "the rc= scan stops at ` log=`")
    # ⛔ AN UNMODELLED TOKEN IS NOT A VERDICT, even when a direct caller supplies one
    # (the reader §13.5 says is next must not be able to turn a new spelling into `dead`).
    v = liv.log_lane_verdict(LR(alive=False, verdict="needs-review", rc="0"))
    check(v.state == "no-verdict",
          "an unmodelled verdict token must not publish `dead`; got %s/%s" % (v.state, v.reason))


@test("T38 the three lanes MEASURED on 2026-11-03 decide correctly (the before/after table)")
def t38():
    # `land-10762`: log frozen 18:46, called dead at 19:07 (21 min), and its tail is
    # `session (27 turns, 2 PRs) saved` + the reflect-hook ran. It FINISHED.
    v = liv.log_lane_verdict(LR(alive=False, verdict="finished", rc="0", size_delta=0,
                                transcript_grew=None, cpu_delta_cs=0, age_ms=21 * M,
                                size=412))
    check(v.state == "finished", "land-10762 finished; got %s/%s" % (v.state, v.reason))
    # `harness-provision-cells`: 210 B artefact, `[verification-gate] ✅ 7 files verified`
    # + `[review-enforcer] ✅ 3 reviewer dispatches`, no lane-bound verdict line at all.
    v = liv.log_lane_verdict(LR(alive=False, verdict="", size=210, size_delta=0,
                                cpu_delta_cs=0, age_ms=60 * M))
    check(v.state == "no-verdict",
          "harness-provision-cells finished without a verdict ⇒ `no-verdict`; got %s" % v.state)
    check(v.state != "dead", "a finished lane must never read dead")
    # `p0-10537` / `p0-5064`: genuinely frozen — re-dispatch was necessary.
    v = liv.log_lane_verdict(LR(alive=True, size_delta=0, transcript_grew=False,
                                cpu_delta_cs=0, age_ms=3 * H))
    check(v.state == "frozen", "a genuinely frozen lane reads frozen; got %s" % v.state)


@test("T39 `_cpu_time_cs` accepts BOTH platforms' `ps` time spellings, and a bad row abstains")
def t39():
    # GNU: mm:ss / hh:mm:ss / dd-hh:mm:ss.  BSD/macOS: MM:SS.cc / HH:MM:SS.cc.
    cases = {
        "00:00": 0, "00:03": 300, "1:02": 6200, "01:02:03": 372300,
        "2-01:02:03": 17652300,
        # ⛔ THE MAC SHAPE. The Mac is where `cmux.app` fleet ancestry (and therefore
        # the fleet's lanes) lives, so rejecting the fractional form made S2
        # permanently unreadable there.
        "0:00.50": 50, "1:02.33": 6233, "1:02:03.45": 372345,
        "": None, "garbage": None, "1:99": None, "1:02:60": None,
    }
    for text, want in cases.items():
        got = liv._cpu_time_cs(text)
        check(got == want, "_cpu_time_cs(%r) => %r, wanted %r" % (text, got, want))

    d = tempfile.mkdtemp(prefix="liv-ps-")
    try:
        table = os.path.join(d, "table")
        shim = os.path.join(d, "ps")

        def run(body):
            with open(table, "w", encoding="utf-8") as fh:
                fh.write(body)
            with open(shim, "w", encoding="utf-8") as fh:
                fh.write("#!/bin/sh\ncat %s\n" % table)
            os.chmod(shim, 0o755)
            return liv.subtree_cpu_cs(100, ps_bin=shim)

        # root 100 (1 s) + child 101 (2 s) + grandchild 102 (0.5 s) = 3.5 s = 350 cs
        got = run("100 1 00:01\n101 100 00:02\n102 101 0:00.50\n200 1 09:00\n")
        check(got == 350, "the subtree sum is root+descendants only; got %r" % (got,))
        # An unparseable row INSIDE the subtree abstains the whole total — a smaller
        # total is how a busy tree reads flat.
        got = run("100 1 00:01\n101 100 nope\n")
        check(got is None, "an unread member abstains the total, never undercounts; got %r" % (got,))
        # …but an unparseable row OUTSIDE it is irrelevant.
        got = run("100 1 00:01\n999 1 nope\n")
        check(got == 100, "a sibling's bad row does not affect our subtree; got %r" % (got,))
        check(liv.subtree_cpu_cs(4242, ps_bin=shim) is None, "an absent pid is not 0 CPU")
        check(liv.subtree_cpu_cs(100, ps_bin=os.path.join(d, "nope")) is None,
              "an unreadable ps is an abstention")
    finally:
        shutil.rmtree(d, ignore_errors=True)


@test("T40 `gather_log_lane` turns every failure path into the ABSTENTION, never a state")
def t40():
    d = tempfile.mkdtemp(prefix="liv-log-")
    try:
        log = os.path.join(d, "L-x.log")
        vfile = os.path.join(d, "verdict")
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("working...\n")

        lr = liv.gather_log_lane(log, os.getpid(), sample=False, now_ms=NOW_MS)
        check(lr.readable and lr.present, "the log reads")
        check(lr.size == 11, "the size is read; got %r" % (lr.size,))
        check(lr.verdict == "", "no verdict line means no verdict; got %r" % (lr.verdict,))
        check(lr.size_delta is None and lr.cpu_delta_cs is None,
              "with sample=False the deltas are NOT READ (None), never 0")
        check(lr.alive is None, "an unfenceable pid (no start time) is an ABSTENTION")
        check(liv.evaluate(liv.Evidence(log_read=lr)).state == "unknown",
              "an unreadable identity/CPU abstains")

        lr = liv.gather_log_lane(os.path.join(d, "nope.log"), os.getpid(), sample=False,
                                 now_ms=NOW_MS)
        check(not lr.readable and not lr.present, "absent is absent")
        check(liv.evaluate(liv.Evidence(log_read=lr)).state == "unknown",
              "an absent log must never publish a state")

        lr = liv.gather_log_lane(d, os.getpid(), sample=False, now_ms=NOW_MS)
        check(not lr.readable and lr.present, "present-but-unreadable is its own fact")
        check(liv.evaluate(liv.Evidence(log_read=lr)).state == "unknown",
              "an unreadable log must never publish a state")

        # the verdict FILE outranks the log's tail, and the rc travels with it
        me = os.getpid()
        with open(log, "a", encoding="utf-8") as fh:
            fh.write("[lane-bound] VERDICT verdict=stalled tag=t pid=%d rc=143 foo=1\n" % me)
        with open(vfile, "w", encoding="utf-8") as fh:
            fh.write("[lane-bound] VERDICT verdict=finished tag=t pid=%d rc=0 foo=1\n" % me)
        lr = liv.gather_log_lane(log, me, verdict_file=vfile, sample=False, now_ms=NOW_MS)
        check((lr.verdict, lr.rc) == ("finished", "0"),
              "the verdict file wins and its rc travels; got %r" % ((lr.verdict, lr.rc),))
        check(lr.verdict_source == "verdict-file", "the source is declared; got %r" % lr.verdict_source)
        lr = liv.gather_log_lane(log, me, sample=False, now_ms=NOW_MS)
        check((lr.verdict, lr.rc, lr.verdict_source) == ("stalled", "143", "log"),
              "the log tail is the fallback; got %r"
              % ((lr.verdict, lr.rc, lr.verdict_source),))

        # (e) a GENUINELY absent pid with a readable log is the TERMINAL branch: the tree
        # is gone and there is no usable verdict, so `no-verdict` — never `frozen`. A
        # reaped child's pid is deterministically absent from `ps`.
        clean_log = os.path.join(d, "L-no-verdict.log")
        with open(clean_log, "w", encoding="utf-8") as fh:
            fh.write("finished its work, said nothing\n")
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        dead_pid = child.pid
        child.wait()
        lr = liv.gather_log_lane(clean_log, dead_pid, sample=False, now_ms=NOW_MS)
        check(lr.alive is False, "a reaped pid is positively absent; got %r" % (lr.alive,))
        v = liv.evaluate(liv.Evidence(log_read=lr))
        check(v.state == "no-verdict", "absent tree + no verdict is `no-verdict`; got %s" % v.state)
        check(v.state != "frozen", "an absent tree is TERMINAL, never frozen")
    finally:
        shutil.rmtree(d, ignore_errors=True)


@test("T41 the `--log-census` seam decodes STRICTLY: an unrecognised token is not a death witness")
def t41():
    d = tempfile.mkdtemp(prefix="liv-census-")
    try:
        log = os.path.join(d, "L.log")
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("x")
        gone = os.path.join(d, "deleted-L.log")   # never created: a pruned/deleted log
        as_dir = os.path.join(d, "adir")
        os.makedirs(as_dir)

        def census(lines, argv=None):
            buf = io.StringIO()
            old = sys.stdin
            sys.stdin = io.StringIO("\n".join(lines) + "\n")
            try:
                with contextlib.redirect_stdout(buf):
                    rc = liv._log_lane_cli(argv or ["--log-census"])
            finally:
                sys.stdin = old
            return rc, [ln.split("\t") for ln in buf.getvalue().splitlines()]

        rc, rows = census([
            "%s\t%s\t0\t0\t\t1\t200000\t9\t0" % (11, log),
            # ⛔ `alive=2` is NOT READ — it used to decode as a POSITIVE False, i.e. a
            # death witness manufactured out of an unreadable field.
            "12\t%s\t0\t0\t\t2\t3000000\t9\t0" % log,
            # ⛔ an unrecognised `transcript_grew` token must not decode as a flat `False`
            # (the same `_tri` allow-list row 12 pins for `alive`); with the byte channel
            # unread the row abstains either way, so ROW 12 is what discriminates it.
            "13\t%s\t?\t0\t\t1\t3000000\t9\tmaybe" % log,
            "14\t%s\t0\t0\tfinished\t0\t3000000\t412\t\t0" % log,
            "15\t-\t?\t?\t\t?\t?\t?\t?",
            # ⛔ each of the guards below is discriminated by exactly one row: without
            # them a dropped guard leaves the whole suite green.
            "24\t%s\t0\t0\tneeds-review\t0\t3000000\t9\t0" % log,
            "25\t%s\t0\t?\t\t1\t3000000\t9\t0" % log,
            "26\t-\t?\t?\t\t0\t3000000\t?\t?",
            # the seam must not ASSERT a log is readable: an absent one abstains, and a
            # deleted log with a verdict must not publish `dead`.
            "27\t%s\t0\t0\t\t1\t3000000\t9\t0" % gone,
            "28\t%s\t0\t0\tfinished\t0\t3000000\t9\t\t0" % gone,
            "29\t%s\t0\t0\t\t1\t3000000\t9\t0" % as_dir,
            # a NEGATIVE cpu delta is a broken reading, not a flat one
            "30\t%s\t0\t-200\t\t1\t3000000\t9\t0" % log,
        ])
        by_pid = {r[0]: (r[1], r[2]) for r in rows}
        check(by_pid["11"] == ("working", "within-window"), "row 11: %r" % (by_pid["11"],))
        check(by_pid["12"][0] == "unknown",
              "an unreadable `alive` must ABSTAIN, not publish a terminal state; got %r"
              % (by_pid["12"],))
        check(by_pid["13"][0] == "unknown",
              "an unrecognised transcript token must ABSTAIN; got %r" % (by_pid["13"],))
        check(by_pid["14"] == ("finished", "bound-verdict:finished"),
              "row 14: %r" % (by_pid["14"],))
        check(by_pid["15"][0] == "unknown", "row 15: %r" % (by_pid["15"],))
        check(by_pid["24"][0] != "dead",
              "an unrecognised verdict token must not publish a state; got %r" % (by_pid["24"],))
        check(by_pid["24"][0] == "no-verdict",
              "row 24 is an exited lane with no usable verdict: %r" % (by_pid["24"],))
        check(by_pid["25"][0] == "unknown",
              "an unread CPU channel at the seam must ABSTAIN, never freeze; got %r"
              % (by_pid["25"],))
        check(by_pid["26"][0] == "unknown",
              "no resolvable log must ABSTAIN even with alive=0; got %r" % (by_pid["26"],))
        check(by_pid["27"][0] == "unknown",
              "an ABSENT log must abstain, never publish a state; got %r" % (by_pid["27"],))
        check(by_pid["28"][0] != "dead",
              "a deleted log with a verdict must NOT publish `dead`; got %r" % (by_pid["28"],))
        check(by_pid["28"][0] == "unknown", "row 28: %r" % (by_pid["28"],))
        check(by_pid["29"][0] == "unknown",
              "a directory is not a readable log; got %r" % (by_pid["29"],))
        check(by_pid["30"][0] == "unknown",
              "a NEGATIVE cpu delta is a broken reading, not a flat one; got %r"
              % (by_pid["30"],))
        check(rc == 3, "an abstaining census exits 3 (cannot-verify); got %r" % (rc,))
    finally:
        shutil.rmtree(d, ignore_errors=True)


@test("T42 the SAMPLED path takes a REAL two-reading delta, in the right direction")
def t42():
    d = tempfile.mkdtemp(prefix="liv-sample-")
    try:
        log = os.path.join(d, "L.log")
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("a")
        seq = iter([100, 900])           # 1.00 s -> 9.00 s CPU across the window
        orig = liv.subtree_cpu_cs
        liv.subtree_cpu_cs = lambda pid, ps_bin=None: next(seq)

        def sleeper(_seconds):
            with open(log, "a", encoding="utf-8") as fh:
                fh.write("bbbb")

        try:
            lr = liv.gather_log_lane(log, os.getpid(), sample=True, sleep_fn=sleeper,
                                     window_ms=1000, now_ms=NOW_MS)
        finally:
            liv.subtree_cpu_cs = orig
        check(lr.cpu_delta_cs == 800,
              "the CPU delta is second-minus-first; got %r" % (lr.cpu_delta_cs,))
        check(lr.size_delta == 4, "the byte delta is second-minus-first; got %r" % (lr.size_delta,))
        # …and the direction MATTERS: a flat/negative delta is what freezes a busy lane.
        live = dataclasses.replace(lr, alive=True, age_ms=3 * H)
        v = liv.log_lane_verdict(live)
        check(v.state == "working", "a sampled lane with real progress is working; got %s" % v.state)
        check(v.reason == "progress:bytes+cpu", "both signals are named; got %r" % v.reason)
    finally:
        shutil.rmtree(d, ignore_errors=True)


@test("T43 a verdict left by an EARLIER dispatch is not this lane's (the appended log)")


def t43():
    d = tempfile.mkdtemp(prefix="liv-stale-")
    try:
        log = os.path.join(d, "lane-3.log")
        # `lane.sh` APPENDS (`tee -a` / `>>`) and nothing truncates the file, so the
        # previous dispatch's verdict stays in the 8 KiB tail.
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("[lane 3] cwd=/repo\n")
            # pid 1 is a LIVE process outside this tree: the binding is verifiable,
            # so the drop is named `stale`. (An unverifiable/dead line pid is named
            # `unbound` and is dropped too — see the second case below.)
            fh.write("[lane-bound] VERDICT verdict=finished tag=lane pid=1 rc=0 "
                     "elapsed=612s log=%s\n" % log)
            fh.write("[lane 3] exited 0\n=== next dispatch ===\n")

        child = subprocess.Popen([sys.executable, "-c", "pass"])
        dead = child.pid
        child.wait()

        lr = liv.gather_log_lane(log, dead, sample=False, now_ms=NOW_MS)
        check(lr.verdict == "",
              "a verdict naming ANOTHER incarnation is DROPPED; got %r" % (lr.verdict,))
        check("stale-bound-verdict" in lr.detail, "and says why; got %r" % lr.detail)

        # An UNVERIFIABLE line pid (an earlier dispatch's child, now reaped) is dropped
        # as well: the over-refusal direction is the only acceptable one, and the state
        # is still terminal-and-honest (`no-verdict`), never `finished`, never `dead`.
        with open(log, "w", encoding="utf-8") as fh:
            # A pid that CANNOT exist: `#define PID_MAX_DEFAULT 4194304` on Linux, so
            # 2**31-1 is never live. (`424242` was used here and is a perfectly legal
            # pid on any host — on a box where it happened to run, `_pid_within`
            # returned False, the reason became `stale`, and this assertion went RED for
            # a non-defect: a false RED in the acceptance suite.)
            fh.write("[lane-bound] VERDICT verdict=finished tag=lane pid=%d rc=0 "
                     "log=%s\n" % (2 ** 31 - 1, log))
        lr = liv.gather_log_lane(log, dead, sample=False, now_ms=NOW_MS)
        check(lr.verdict == "", "an unverifiable binding is dropped; got %r" % (lr.verdict,))
        check("unbound-bound-verdict" in lr.detail, "and named; got %r" % lr.detail)
        check(liv.evaluate(liv.Evidence(log_read=lr)).state == "no-verdict",
              "still terminal, still honest")
        # ⛔ RE-GATHER: the previous sub-case already dropped its verdict, so evaluating
        # that stale `LogRead` asserted a conclusion about an object the appended log
        # never reached — "asserted evidence it does not have", the class this suite's
        # own header warns about.
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("[lane 3] cwd=/repo\n")
            fh.write("[lane-bound] VERDICT verdict=finished tag=lane pid=1 rc=0 "
                     "elapsed=612s log=%s\n" % log)
            fh.write("[lane 3] exited 0\n=== next dispatch ===\n")
        lr = liv.gather_log_lane(log, dead, sample=False, now_ms=NOW_MS)
        check(lr.verdict == "", "the appended log's stale verdict is dropped; got %r"
              % (lr.verdict,))
        v = liv.evaluate(liv.Evidence(log_read=lr))
        check(v.state == "no-verdict",
              "the previous dispatch's `finished` must NOT be published as this lane's; got %s"
              % v.state)
        check(v.state != "finished" and v.state != "dead",
              "never a false PASS and never a death")
        check("stale-bound-verdict" in v.detail,
              "the reason travels into the verdict; got %r" % v.detail)

        # …and a verdict naming THIS incarnation is still adopted.
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("[lane 3] cwd=/repo\n")
            fh.write("[lane-bound] VERDICT verdict=finished tag=lane pid=%d rc=0 log=%s\n"
                     % (dead, log))
        lr = liv.gather_log_lane(log, dead, sample=False, now_ms=NOW_MS)
        check(lr.verdict == "finished", "a bound verdict IS adopted; got %r" % (lr.verdict,))
        # …an UNUSABLE pid token (5000 digits: int() would raise "Exceeds the limit") is
        # DROPPED, never adopted and never an exception.
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("[lane-bound] VERDICT verdict=finished tag=lane pid=%s rc=0\n"
                     % ("9" * 5000))
        lr = liv.gather_log_lane(log, dead, sample=False, now_ms=NOW_MS)
        check(lr.verdict == "", "an unusable pid token is dropped; got %r" % (lr.verdict,))
        check("unbound-bound-verdict" in lr.detail, "and named; got %r" % lr.detail)
        check("invalid-bound-verdict-pid" not in lr.detail,
              "the CAP is what dropped it, not the fallback guard; got %r" % lr.detail)
        # …and the FALLBACK guard is executed too, not just asserted: a caller that
        # bypasses `parse_bound_pid` hands a non-pid token straight to the binding.
        bad = liv.LogRead(verdict="finished", verdict_line_pid="\u00b2\u00b2",
                          verdict_source="caller")
        why, _ = liv._bind_verdict(bad, os.getpid())
        check(why and "invalid-bound-verdict-pid" in why,
              "a non-pid token is dropped by name, never int()-ed: got %r" % (why,))
        # …and one with NO `pid=` at all is adopted but declared unbound.
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("[lane-bound] VERDICT verdict=finished tag=lane rc=0\n")
        lr = liv.gather_log_lane(log, dead, sample=False, now_ms=NOW_MS)
        check(lr.verdict == "finished", "an unbound verdict is adopted; got %r" % (lr.verdict,))
        check("bound-verdict-without-pid" in liv.evaluate(liv.Evidence(log_read=lr)).detail,
              "and the PUBLISHED verdict says it is unbound (a reader cannot otherwise "
              "tell a verified binding from an unbound one)")
        # ⛔ A `pid=` FIELD THAT IS PRESENT BUT UNPARSEABLE IS *NOT* AN ABSENT ONE (review P2).
        # "absent from the line" is the ADOPT row of the doc's binding table; "a pid that cannot
        # be resolved" is the DROP row. Collapsing the two into "" published a verdict whose
        # binding was never checked — the same fail-open class, one surface over from the
        # census's column 11.
        #
        # ⛔ AND THE PRODUCER IS NAMED NARROWLY ON PURPOSE. An earlier version of this comment
        # said `pid=abc` was "reachable from the shipped writer" via `lane-bound.sh --pid`. A
        # later reviewer FALSIFIED that: `--pid` is verbatim at `:161`, but `watch` mode refuses
        # a non-numeric pid first (`:465` -> `pid_alive`, `case "${1:-}" in *[!0-9]*) return 1`
        # at `:234`) and `run` mode overwrites `PID=$!` (`:475`). Measured:
        # `lane-bound.sh watch --pid abc` -> "refusing: ... not a live process", rc=2, nothing
        # emitted. So this arm is defence in depth against a FOREIGN / hand-edited
        # `$log.lanebound`, a restored state dir, or a future producer — not a live bypass. The
        # guard is still required by the doc's binding table, and `_bind_verdict`'s
        # `invalid-bound-verdict-pid` arm existed already but was unreachable from the parser.
        for tok in ("abc", "?", "0x10"):
            with open(log, "w", encoding="utf-8") as fh:
                fh.write("[lane-bound] VERDICT verdict=finished tag=lane pid=%s rc=0\n" % tok)
            lr = liv.gather_log_lane(log, dead, sample=False, now_ms=NOW_MS)
            check(lr.verdict == "",
                  "a PRESENT-but-unusable pid=%r is dropped, not adopted; got %r"
                  % (tok, lr.verdict))
            check("unbound-bound-verdict" in lr.detail,
                  "and dropped with the SAME reason the census gives; got %r" % lr.detail)
            check("bound-verdict-without-pid" not in lr.detail,
                  "never claiming the field was absent when it was present; got %r" % lr.detail)
        # …and the boundary is not over-broad: `ppid=` is not a `pid=` field, and a line with
        # neither is still the ADOPT row. A `\\b` needs a non-word char before `p`, which is
        # the one thing keeping this guard from swallowing a legitimate unbound line.
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("[lane-bound] VERDICT verdict=finished tag=lane ppid=77 rc=0\n")
        lr = liv.gather_log_lane(log, dead, sample=False, now_ms=NOW_MS)
        check(lr.verdict == "finished",
              "`ppid=` is not a `pid=` field — the line is still adopted; got %r" % (lr.verdict,))
    finally:
        shutil.rmtree(d, ignore_errors=True)


@test("T44 a stale --verdict-file is bound like the tail, and cannot outrank a fresh log line")


def t44():
    d = tempfile.mkdtemp(prefix="liv-vfile-")
    try:
        log = os.path.join(d, "lane-1.log")
        vfile = os.path.join(d, "lane-1.log.lanebound")
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        dead = child.pid
        child.wait()
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("[lane-bound] VERDICT verdict=finished tag=lane pid=%d rc=0\n" % dead)

        # 1. The file names ANOTHER incarnation: dropped, named, and the fresh correctly
        #    bound line in the log's own tail is what gets adopted.
        with open(vfile, "w", encoding="utf-8") as fh:
            fh.write("[lane-bound] VERDICT verdict=stalled tag=lane pid=1 rc=137\n")
        lr = liv.gather_log_lane(log, dead, verdict_file=vfile, sample=False, now_ms=NOW_MS)
        check(lr.verdict_source == "log",
              "the stale file must not outrank the lane's own line; got source=%r"
              % (lr.verdict_source,))
        check((lr.verdict, lr.rc) == ("finished", "0"),
              "and the bound log line is adopted; got %r" % ((lr.verdict, lr.rc),))

        # 2. The file names THIS incarnation: adopted from the file.
        with open(vfile, "w", encoding="utf-8") as fh:
            fh.write("[lane-bound] VERDICT verdict=stalled tag=lane pid=%d rc=137\n" % dead)
        lr = liv.gather_log_lane(log, dead, verdict_file=vfile, sample=False, now_ms=NOW_MS)
        check((lr.verdict, lr.verdict_source) == ("stalled", "verdict-file"),
              "a bound file verdict IS adopted; got %r" % ((lr.verdict, lr.verdict_source),))

        # 3. No log line at all + a stale file: dropped, terminal, never `finished`.
        os.remove(log)
        with open(vfile, "w", encoding="utf-8") as fh:
            fh.write("[lane-bound] VERDICT verdict=finished tag=lane pid=1 rc=0\n")
        lr = liv.gather_log_lane(log, dead, verdict_file=vfile, sample=False,
                                 now_ms=NOW_MS, window_ms=1)
        check(lr.verdict == "", "a stale file alone is dropped; got %r" % (lr.verdict,))
        v = liv.evaluate(liv.Evidence(log_read=lr))
        check(v.state not in ("finished", "dead", "frozen"),
              "and no state is manufactured from it; got %s" % v.state)
    finally:
        shutil.rmtree(d, ignore_errors=True)


@test("T45 the drop reason APPENDS to acquisition's own facts instead of replacing them")


def t45():
    d = tempfile.mkdtemp(prefix="liv-append-")
    try:
        log = os.path.join(d, "absent.log")          # never created
        vfile = os.path.join(d, "v")
        with open(vfile, "w", encoding="utf-8") as fh:
            fh.write("[lane-bound] VERDICT verdict=finished tag=lane pid=1 rc=0\n")
        lr = liv.gather_log_lane(log, os.getpid(), verdict_file=vfile, sample=False,
                                 now_ms=NOW_MS, window_ms=1)
        v = liv.evaluate(liv.Evidence(log_read=lr))
        check(v.state == "unknown", "an absent log is the abstention; got %s" % v.state)
        check("absent" in v.detail,
              "and the ABSENCE is still what it reports, not the binding note; got %r"
              % v.detail)
    finally:
        shutil.rmtree(d, ignore_errors=True)


@test("T46 the --log-census seam enforces the verdict binding too (col 11 = verdict_pid)")


def t46():
    d = tempfile.mkdtemp(prefix="liv-census-")
    try:
        log = os.path.join(d, "L.log")
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("x\n")
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        dead = child.pid
        child.wait()
        size = os.path.getsize(log)

        def row(verdict_pid):
            return ("%d\t%s\t0\t?\tfinished\t0\t999999\t%d\t?\t0\t%s\n"
                    % (dead, log, size, verdict_pid))

        # A verdict naming ANOTHER live incarnation must not be published.
        out = subprocess.run([sys.executable, liv.__file__, "--log-census"],
                             input=row("1").encode(), stdout=subprocess.PIPE).stdout.decode()
        check("finished" not in out,
              "the census must not publish another incarnation's verdict; got %r" % out)
        check("no-verdict" in out,
              "it must fall to the terminal-and-honest state; got %r" % out)

        # …and one naming THIS one still is.
        out = subprocess.run([sys.executable, liv.__file__, "--log-census"],
                             input=row(str(dead)).encode(),
                             stdout=subprocess.PIPE).stdout.decode()
        check("finished" in out,
              "a correctly bound census verdict IS published; got %r" % out)

        # ⛔ A PRESENT-BUT-UNUSABLE col 11 IS NOT AN ABSENT ONE. `?` is the census's own
        # documented "NOT READ" token, so a caller following the convention handed the
        # seam an unread pid — and collapsing that to "" fell through to the ADOPT arm
        # ("column 11 absent"), publishing a previous dispatch's `finished` while
        # `gather_log_lane` DROPPED the identical token. Measured before this fix: all
        # three tokens below published `finished`.
        for unusable in ("?", "zzz", "9" * 30):
            out = subprocess.run([sys.executable, liv.__file__, "--log-census"],
                                 input=row(unusable).encode(),
                                 stdout=subprocess.PIPE).stdout.decode()
            check("finished" not in out,
                  "a present-but-unusable col 11 (%r) must NOT publish the verdict; got %r"
                  % (unusable[:8], out))
            check("no-verdict" in out,
                  "…it falls to the honest terminal state; got %r" % out)
    finally:
        shutil.rmtree(d, ignore_errors=True)


@test("T47 a SHRINKING log is a broken reading, never no-output (frozen is refused)")


def t47():
    # A log cannot lose bytes without activity. Read as "flat", a truncate/rotate during
    # the sample window froze a lane whose log had just been REWRITTEN.
    lr = liv.LogRead(readable=True, present=True, path="/x", size_delta=-990,
                     cpu_delta_cs=0, transcript_grew=None, alive=True,
                     age_ms=liv.LOG_FREEZE_MS + 60000, window_ms=liv.LOG_WINDOW_MS)
    v = liv.evaluate(liv.Evidence(log_read=lr))
    check(v.state == "unknown", "a shrink abstains; got %s/%s" % (v.state, v.reason))
    check(v.state != "frozen", "never frozen on a broken delta")
    # a POSITIVELY FLAT transcript must not rescue an unreadable byte channel: with
    # `is None` the shrink escaped to `frozen` on both shipped surfaces
    lr.transcript_grew = False
    v = liv.evaluate(liv.Evidence(log_read=lr))
    check(v.state == "unknown", "a shrink + flat transcript abstains; got %s/%s"
          % (v.state, v.reason))
    lr.transcript_grew = None
    # a genuinely flat log still freezes, so the guard is not a blanket abstain
    lr.size_delta = 0
    v = liv.evaluate(liv.Evidence(log_read=lr))
    check(v.state == "frozen", "a flat log still freezes; got %s" % v.state)


@test("T48 the census survives the `?` it prints itself, and declares an unbound row")


def t48():
    d = tempfile.mkdtemp(prefix="liv-census2-")
    try:
        log = os.path.join(d, "L.log")
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("x")
        size = os.path.getsize(log)

        def census(text):
            r = subprocess.run([sys.executable, liv.__file__, "--log-census"],
                               input=text.encode(), stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
            return r.returncode, r.stdout.decode() + r.stderr.decode()

        # `?` is the census's OWN not-read token for every other column; int("?") used to
        # abort the whole run with a traceback after printing only the rows before it.
        rc, out = census("?\t%s\t0\t?\tfinished\t0\t999999\t%d\t?\t0\t1\n" % (log, size))
        check("Traceback" not in out, "a `?` pid must not abort the census; got %r" % out)
        check("finished" not in out, "and must not publish a state; got %r" % out)

        # an unusable pid token (5000 digits) must not raise out of int() either
        rc, out = census("%s\t%s\t0\t?\tfinished\t0\t999999\t%d\t?\t0\t1\n"
                         % ("9" * 5000, log, size))
        check("Traceback" not in out, "an unusable pid token must not abort; got %r" % out[:200])
        check("finished" not in out, "and must not publish a state; got %r" % out[:200])
        # A 10-column row carries no `verdict_pid`, so the adoption must be DECLARED.
        rc, out = census("123456\t%s\t0\t?\tfinished\t0\t999999\t%d\t?\t0\n" % (log, size))
        check("bound-verdict-without-pid" in out,
              "an unbound adoption is declared on the census surface; got %r" % out)

        # ⛔ COLUMN 11 PRESENT BUT UNRESOLVABLE IS NOT COLUMN 11 ABSENT (cycle-6 review, P2).
        # `?` is this census's own not-read token, and it used to be collapsed into "absent",
        # which took the ADOPT arm and published a verdict whose binding was never checked —
        # with a detail claiming `bound-verdict-without-pid`, i.e. "about a line that DID carry
        # a pid". The doc's binding table says a pid that cannot be resolved is DROPPED.
        rc, out = census("123456\t%s\t0\t?\tfinished\t0\t999999\t%d\t?\t0\t?\n" % (log, size))
        check("finished" not in out,
              "an UNRESOLVABLE col-11 pid must DROP the verdict, not adopt it; got %r" % out)
        check("bound-verdict-without-pid" not in out,
              "and must not claim the pid was absent — it was present and unusable; got %r" % out)
        check("unbound-bound-verdict" in out,
              "it must drop with the SAME reason `--verdict-file` gives; got %r" % out)
    finally:
        shutil.rmtree(d, ignore_errors=True)


@test("T49 the no-progress abstention names the FACT, not only the class")


def t49():
    lr = liv.LogRead(readable=True, present=True, path="/x", size_delta=-990,
                     cpu_delta_cs=0, transcript_grew=None, alive=True,
                     age_ms=liv.LOG_FREEZE_MS + 1000, window_ms=liv.LOG_WINDOW_MS)
    v = liv.evaluate(liv.Evidence(log_read=lr))
    check(v.state == "unknown", "a broken byte read abstains; got %s" % v.state)
    check("bytes_delta=-990" in v.detail,
          "and the detail names WHAT was broken; got %r" % v.detail)
    # The census's `?` row is the same shape and must be equally legible.
    lr = liv.LogRead(readable=True, present=True, path="/x", size_delta=None,
                     cpu_delta_cs=0, transcript_grew=None, alive=True,
                     age_ms=liv.LOG_FREEZE_MS + 1000, window_ms=liv.LOG_WINDOW_MS)
    v = liv.evaluate(liv.Evidence(log_read=lr))
    check("bytes_delta=" in v.detail, "an unread field is named too; got %r" % v.detail)
    # `"\u00b2".isdigit()` is True but `int("\u00b2")` raises; the contract here is None.
    for bad in ("\u00b2:00", "1:\u00b200", "\u00b2-01:00:00", "0:00.\u00b2"):
        check(liv._cpu_time_cs(bad) is None,
              "a non-ASCII digit is unreadable, not an exception: %r" % bad)


@test("T50 the LOG STATES are a pinned vocabulary, and overlap the session tuple only on "
       "`dead`/`unknown`")
def t50():
    # ⛔ `STATES` IS FROZEN BY A TEST (it has been unchanged since #1178), and that freeze is
    # the reason this axis carries a SECOND tuple instead of widening the first. Without the
    # same pin here, a rename or an added log state kept all tests green while silently
    # breaking every consumer and the doc's disjointness claim.
    check(liv.LOG_STATES == ("working", "frozen", "finished", "no-verdict", "dead", "unknown"),
          "the log-state vocabulary is exactly the documented one; got %r" % (liv.LOG_STATES,))
    check(set(liv.LOG_STATES) & set(liv.STATES) == {"dead", "unknown"},
          "the two tuples overlap ONLY on dead/unknown; got %r"
          % (set(liv.LOG_STATES) & set(liv.STATES),))
    # …and the session tuple is still the frozen five, so the second tuple was not bought
    # by widening the first.
    check(liv.STATES == ("dead", "running-quiet", "wedged", "idle", "unknown"),
          "the session tuple is unchanged; got %r" % (liv.STATES,))


class Mutation:
    def __init__(self, test_name, target, old, new, why):
        self.test_name = test_name
        self.target = target          # "module" | "lib"
        self.old = old
        self.new = new
        self.why = why


MUTATIONS = [
    Mutation(
        "T32", "module",
        '    if kinds:\n        numbers = []',
        '    if False and kinds:\n        numbers = []',
        "the progress VETO is dropped, so a lane working through a long silent tool call "
        "reads `frozen` — the log-mtime-keyed behaviour the 2026-11-03 table measured",
    ),
    Mutation(
        "T33", "module",
        '    if lr.alive is False:',
        '    if False and lr.alive is False:',
        "an EXITED process falls through to the freeze ladder, so a finished lane reads "
        "`frozen` and invites a re-dispatch that re-does finished work",
    ),
    Mutation(
        "T34", "module",
        '    if lr.age_ms < freeze_ms:',
        '    if lr.age_ms < 0:',
        "the freeze WINDOW is dropped, so any single flat reading convicts a live lane",
    ),
    Mutation(
        "T35", "module",
        '        return Verdict("unknown", "log-unreadable", detail=lr.detail or ("path=%s" % (lr.path or "?")))',
        '        return Verdict("dead", "log-unreadable", detail=lr.detail or ("path=%s" % (lr.path or "?")))',
        "an ABSENT log becomes a death witness — the `no-log-evidence` fail-open `lane-reap.sh` "
        "already refuses, reintroduced on the diagnostic",
    ),
    Mutation(
        "T36", "module",
        '        if ev.sid or ev.claim_read is not None or ev.candidates or ev.record is not None \\\n'
        '                or ev.jsonl_grew is not None or ev.jsonl_age_ms is not None \\\n'
        '                or ev.tool is not None or ev.jsonl_turn is not None \\\n'
        '                or not ev.ps_ok or not ev.store_ok:\n',
        '        if False:\n',
        "the log axis accepts a query that ALSO carries session/claim evidence, so a log "
        "read can mask it (the #1777 B7 shape, reconstructed on the new axis)",
    ),
    Mutation(
        "T50", "module",
        '        if ev.sid or ev.claim_read is not None or ev.candidates or ev.record is not None \\\n'
        '                or ev.jsonl_grew is not None or ev.jsonl_age_ms is not None \\\n'
        '                or ev.tool is not None or ev.jsonl_turn is not None \\\n'
        '                or not ev.ps_ok or not ev.store_ok:\n',
        '        if ev.sid or ev.claim_read is not None or ev.candidates or ev.record is not None \\\n'
        '                or ev.jsonl_grew is not None or ev.jsonl_age_ms is not None \\\n'
        '                or ev.tool is not None or ev.jsonl_turn is not None:\n',
        "the masking refusal ignores the SESSION AXIS'S ABSTENTIONS, so a log read "
        "resolves over `unknown/ps-unreadable` — and a `frozen` log read then CONVICTS "
        "a lane on the evidence it discarded (the #1777 B7 shape on a new axis)",
    ),
    Mutation(
        "T37", "module",
        '            if verdict in BOUND_FINISHED:',
        '            if True:',
        "every bound verdict reads `finished`, so a lane the bound KILLED (stalled / "
        "exceeded-wallclock) is reported as having completed",
    ),
    Mutation(
        "T35", "module",
        '    if no_output or no_cpu:',
        '    if no_output and no_cpu:',
        "the abstention conjunct becomes `and`, so a flat log with an UNREADABLE CPU "
        "channel reads `frozen` — `frozen` on ONE signal, which is the log-mtime defect "
        "rebuilt inside its own fix",
    ),
    Mutation(
        "T36", "module",
        '    if ev.log_read is not None:\n        # \u26d4 THE REFUSAL',
        '    if True:\n        # \u26d4 THE REFUSAL',
        "the axis stops being INERT for session callers: every query enters the log "
        "branch, so a session verdict can be replaced by a log one (or by the refusal)",
    ),
    Mutation(
        "T37", "module",
        '                if lr.rc not in BOUND_OK_RC:',
        '                if False:',
        "the rc conjunct is dropped, so `verdict=finished rc=7` — a CRASHED lane — reads "
        "`finished` and nobody re-dispatches the work it lost",
    ),
    Mutation(
        "T39", "module",
        '    return ((days * 24 + hh) * 3600 + mm * 60 + ss) * 100 + frac',
        '    return ((days * 24 + hh) * 3600 + mm * 60 + ss) * 100',
        "BSD/macOS fractional seconds are dropped, so a sub-second CPU delta reads as a "
        "smaller (or flat) number on the only platform where the fleet has lanes",
    ),
    Mutation(
        "T39", "module",
        '        if cpu.get(p) is None:\n',
        '        if False:\n',
        "an unparseable row inside the subtree is silently skipped, so the total "
        "undercounts and a busy tree reads flat -> `frozen`",
    ),
    Mutation(
        "T41", "module",
        '                return None  # "", "?", "2", "gone" \u2026 \u2014 NOT READ',
        '                return False',
        "the census seam decodes any unrecognised token as a POSITIVE False, i.e. it "
        "manufactures a death witness out of an unread field",
    ),
    Mutation(
        "T42", "module",
        '            lr.cpu_delta_cs = cpu1 - cpu0',
        '            lr.cpu_delta_cs = cpu0 - cpu1',
        "the sample delta is inverted, so every busy lane reads flat and freezes after the "
        "window (the sampled path had no test)",
    ),
    Mutation(
        "T35", "module",
        '    no_cpu = (lr.cpu_unreadable or lr.cpu_delta_cs is None or lr.cpu_delta_cs < 0)',
        '    no_cpu = (lr.cpu_unreadable or lr.cpu_delta_cs is None)',
        "a NEGATIVE CPU delta stops abstaining, so a broken reading reads as flat and "
        "freezes a lane that may be working (the rule `lane-reap.sh` states)",
    ),
    Mutation(
        "T37", "module",
        '        verdict = lr.verdict if lr.verdict in BOUND_VERDICTS else ""',
        '        verdict = lr.verdict',
        "the verdict function stops validating its input, so a direct caller can turn a "
        "future producer's token into `dead/bound-verdict:<it>`",
    ),
    Mutation(
        "T37", "module",
        '    head = line.split(" log=")[0]',
        '    head = line',
        "the rc= scan runs to the end of the line, so an `rc=` inside `log=` supplies the "
        "exit status",
    ),
    Mutation(
        "T41", "module",
        '                    if stat.S_ISREG(st.st_mode):',
        '                    if True:',
        "the census seam stops checking the path is a regular file, so a directory reads as "
        "a readable log and its 0-byte delta looks flat",
    ),
    Mutation(
        "T40", "module",
        '        if not stat.S_ISREG(st.st_mode):',
        '        if False:',
        "a path that stats but is not a regular file (a directory) reads as a readable log, "
        "so its 0-byte delta looks flat",
    ),
    Mutation(
        "T1", "lib",
        '    if [ "$diff" -le "$FENCE_TOLERANCE_SECONDS" ]; then',
        '    if [ "$diff" -ge 0 ]; then',
        "the fence is ignored, so any live pid reads as the holder — pid reuse is not defeated",
    ),
    Mutation(
        "T2", "module",
        'WITNESS_OBSERVED = frozenset({"absent", "zombie"})',
        'WITNESS_OBSERVED = frozenset({"absent", "zombie", "off-fence"})',
        "v4's rule: off-fence counts as a death witness, so a live lane reads dead (C1)",
    ),
    Mutation(
        "T3", "module",
        '    for pid in argv_pids or []:\n'
        '        pid = int(pid)\n'
        '        cands.append(Candidate(pid, probe_fn(pid, None, "argv"), "argv", None))\n'
        '    return cands',
        '    return cands',
        "no argv candidate source, so a stale record + untagged live writer reads dead (C2)",
    ),
    Mutation(
        "T4", "lib",
        '    case "$pid" in \'\'|*[!0-9]*) return 2 ;; esac\n'
        '    table="$(pid_ps_table)" || return 2',
        '    case "$pid" in \'\'|*[!0-9]*) return 2 ;; esac\n'
        '    table="$(pid_ps_table)" || return 1',
        "a failed read is conflated with absence, manufacturing dead out of a failed command (C3)",
    ),
    Mutation(
        "T5", "module",
        '    return bool(candidates) and all(c.observed in WITNESS_OBSERVED for c in candidates)',
        '    return all(c.observed in WITNESS_OBSERVED for c in candidates)',
        "the dead predicate becomes vacuously true for an empty candidate set (C4)",
    ),
    Mutation(
        "T6", "module",
        'WITNESS_OBSERVED = frozenset({"absent", "zombie"})',
        'WITNESS_OBSERVED = frozenset({"absent"})',
        "a zombie stops being a dead witness, so a dead lane reads unknown/wedged",
    ),
    Mutation(
        "T7", "module",
        '    holders = [c for c in cands if c.observed == HOLDER]',
        '    holders = [cands[0]] if cands and cands[0].observed == HOLDER else []',
        "one record (the first/newest) decides instead of the union — a ghost tag wins",
    ),
    Mutation(
        "T8", "module",
        '    if ev.jsonl_grew is True:',
        '    if ev.jsonl_grew is True and holders:',
        "growth without a fenced holder loses its liveness meaning and falls into the dead path (C6)",
    ),
    Mutation(
        "T9", "module",
        '    if tool.turn_active:\n'
        '        bound = tool_stall_ms(tool.hard_cap_ms)\n'
        '    else:\n'
        '        bound = min(tool_stall_ms(tool.hard_cap_ms), tool.heartbeat_timeout_ms)\n'
        '    return _exceeds(tool.tool_age_ms, bound)',
        '    bound = tool_stall_ms(tool.hard_cap_ms)\n'
        '    return _exceeds(tool.tool_age_ms, bound)',
        "the turn-inactive min(4h, 30min) branch is dropped — the fail-OPEN direction (C5)",
    ),
    Mutation(
        "T10", "module",
        '    return (now_s - ts) * 1000 <= veto_ms',
        '    return True',
        "the #947 veto is unbounded, so one record immunises a lane forever (C9)",
    ),
    Mutation(
        "T11", "module",
        '        if (not tool.tool_updates and cpu_attributable(tool)\n'
        '                and _exceeds(tool.tool_age_ms, STREAM_STALL_MS)):\n',
        '        if (not tool.tool_updates\n'
        '                and _exceeds(tool.tool_age_ms, STREAM_STALL_MS)):\n',
        "CPU-flatness of a non-attributable tool (nested `task`) arms the kill (C8)",
    ),
    Mutation(
        "T12", "module",
        '    if not ev.ps_ok:\n'
        '        return Verdict("unknown", "ps-unreadable")\n',
        '',
        "the ps-availability guard is removed, so a failed read falls into the dead path (C3)",
    ),
    Mutation(
        "T18", "module",
        'NON_TERMINAL_STOP_REASONS = frozenset({"toolUse"})',
        'NON_TERMINAL_STOP_REASONS = frozenset()',
        "`toolUse` with no parseable call goes terminal, so a mid-turn lane reads resting (fail-open)",
    ),
    Mutation(
        "T18", "module",
        'CALL_DISCARDING_STOP_REASONS = frozenset({"error", "aborted"})',
        'CALL_DISCARDING_STOP_REASONS = frozenset({"error", "aborted", "length"})',
        "the cycle-1 P0: `length`+calls is treated as discarding, so a still-running turn reads ended",
    ),
    Mutation(
        "T18", "module",
        '        if calls and stop not in CALL_DISCARDING_STOP_REASONS:',
        '        if calls and stop in NON_TERMINAL_STOP_REASONS:',
        "the pre-fix rule — only `toolUse` is open, so `length`+calls reads ended (P0)",
    ),
    Mutation(
        "T18", "module",
        'CALL_DISCARDING_STOP_REASONS = frozenset({"error", "aborted"})',
        'CALL_DISCARDING_STOP_REASONS = frozenset()',
        "`error`/`aborted` calls stop being discarded, so a discarded turn reads open (over-report)",
    ),
    Mutation(
        "T14", "module",
        '        if calls and stop not in CALL_DISCARDING_STOP_REASONS:\n'
        '            return Turn(True, "turn-open:pending-tool-call",\n'
        '                        "unanswered %s" % ", ".join(calls))\n',
        '        if calls and stop not in CALL_DISCARDING_STOP_REASONS:\n'
        '            return Turn(True, "turn-open:pending-tool-call", "")\n',
        "the verdict stops naming the open call, so the report no longer says why (#1254)",
    ),
    Mutation(
        "T19", "module",
        '    if (last_entry is not None and isinstance(last_entry, dict)\n'
        '            and last_entry.get("type") == "compaction"):\n'
        '        return turn_from_entry(last_entry)\n',
        '',
        "the compaction-tail abstention is dropped, so the turn before it decides (P1)",
    ),
    Mutation(
        "T19", "module",
        '    if isinstance(entry, dict) and entry.get("type") == "compaction":\n'
        '        return Turn(False, "tail-after-compaction",\n'
        '                    "a compaction entry is the last entry", abstain=True)\n',
        '',
        "turn_from_entry stops treating a compaction as no-boundary, so it reads as a decided turn",
    ),
    Mutation(
        "T17", "module",
        '    turn = ev.jsonl_turn\n'
        '    if turn is None:\n'
        '        return Verdict("unknown", "turn-state-unknown", holder_pid=holder.pid)\n',
        '    turn = ev.jsonl_turn or Turn(True, "turn-open:no-terminal-stop", "")\n'
        '    if turn is None:\n'
        '        return Verdict("unknown", "turn-state-unknown", holder_pid=holder.pid)\n',
        "an unclassifiable boundary is treated as an open turn — absence of evidence reads wedged (#1254)",
    ),
    Mutation(
        "T13", "module",
        '    if not turn.stalled:\n'
        '        return Verdict("running-quiet", turn.reason, holder_pid=holder.pid, detail=turn.detail)\n',
        '    if False:\n'
        '        return Verdict("running-quiet", turn.reason, holder_pid=holder.pid, detail=turn.detail)\n',
        "the turn-ended protection is dropped, so a merely-idle REPL reads wedged again (#1254)",
    ),
    Mutation(
        "T16", "module",
        '    holders = [c for c in cands if c.observed == HOLDER]',
        '    if ev.jsonl_turn is not None and ev.jsonl_turn.stalled:\n'
        '        return Verdict("unknown", "turn-open-hold")\n'
        '    holders = [c for c in cands if c.observed == HOLDER]',
        "the turn boundary gates identity, so a stalled lane with every incarnation gone stops being dead (#1254)",
    ),
    Mutation(
        "T15", "module",
        '        for raw in reversed(lines):',
        '        for raw in lines:',
        "the tail scan runs forward, so an ancient boundary decides instead of the last (#1254)",
    ),
    Mutation(
        "T20", "module",
        '        return Turn(False, "turn-unknown:%s" % stop, abstain=True)\n',
        '        return Turn(False, "turn-ended", "terminal stopReason=%s" % stop)\n',
        "the pre-fix fall-through returns: an unrecognized stop reason reads RESTING (fail-open, #1272)",
    ),
    Mutation(
        "T21", "module",
        '    if not isinstance(stamp, str) or not stamp:\n        return None\n',
        '    if not isinstance(stamp, str) or not stamp:\n        return 0\n',
        "an unreadable entry timestamp is read as 0, so the derived age becomes `now - 0` (~56 "
        "years) and EXCEEDS every backstop — the veto is EXPIRED on evidence the parser could not "
        "read, which is the FAIL-OPEN direction (#5389 a)",
    ),
    Mutation(
        "T22", "module",
        '    if progress == NO_PROGRESS:\n',
        '    if True:\n',
        "the pre-#5389 rule returns: silence ALONE expires the veto, so a tool still burning CPU "
        "is expired while progressing (tortoise #5387) — the false cut this mirrors (#5389 b)",
    ),
    Mutation(
        "T22", "module",
        '        if tool.tool_updates and _exceeds(tool.silence_age_ms, STREAM_STALL_MS):\n'
        '            return True\n',
        '        if tool.tool_updates:\n'
        '            return _exceeds(tool.silence_age_ms, STREAM_STALL_MS)\n',
        "the clause returns UNCONDITIONALLY, so a no-progress shape whose silence is still inside "
        "S never falls through to the age backstop and the veto is forever (T9; #5389 cycle-2 F1)",
    ),
    Mutation(
        "T21", "module",
        '    age = max(0, now_ms - started)\n',
        '    age = None\n',
        "the derived age is left UNMEASURABLE, and an unknown age never expires "
        "(`_exceeds(None, ...)` is False) — so the veto becomes PERMANENT and `idle` becomes "
        "unreachable (T9; #5389 review, cycles 1 and 3)",
    ),
    Mutation(
        "T21", "module",
        '        started = min(started, mtime_ms)\n',
        '        started = max(started, mtime_ms)\n',
        "a FUTURE-dated entry stamp is no longer bounded by the transcript's own mtime, so "
        "`now - started` clamps to 0 and STAYS 0 — the 4h age backstop is never reached and "
        "the veto is PERMANENT (T9; #5389 review F2)",
    ),
    Mutation(
        "T23", "module",
        '        tool = tool_from_jsonl(sfile, now, silence_age_ms=age)\n',
        '        tool = None\n',
        "the #5389 (a) wiring is removed: no store record carries the fields (0 of 1011), so the "
        "veto is dead again and a lane inside one long read reads `wedged`",
    ),
    Mutation(
        "T24", "module",
        '    if msg.get("stopReason") in CALL_FAILED_STOP_REASONS:\n        return None\n',
        '',
        "a `length`-truncated message's calls are treated as still in flight, so the veto "
        "manufactures a tool pi already FAILED and the lane stands quiet past S where the "
        "watchdog's zero-tool `stream-stall` cut (#5389 review P2)",
    ),
    Mutation(
        "T25", "module",
        '    if not cr.readable:',
        '    if False:',
        "a failed registry read is no longer distinguished from an empty one (B2/B3)",
    ),
    Mutation(
        "T26", "module",
        '    if not cr.claims:',
        '    if False and not cr.claims:',
        "an absence stops abstaining and falls through to another reason (the #1777 defect itself)",
    ),
    Mutation(
        "T27", "module",
        '        return Verdict("unknown", "claim-held",',
        '        return Verdict("unknown", "claim-held", holder_pid=held[0].owner_pid,',
        "an unprobeable claim asserts an incarnation by pid (a second identity rule, #1178)",
    ),
    Mutation(
        "T27", "module",
        '    if claim.age_s is not None:\n        parts.append("age_s=%d" % claim.age_s)\n',
        '',
        "the claim age is dropped from the detail, so a holder is no longer reported with its age",
    ),
    Mutation(
        "T28", "module",
        '        return Verdict("unknown", "claim-held",',
        '        return Verdict("running-quiet", "claim-held",',
        "a claim sheds its abstention and can be read as a green light by an exit-code consumer (B4)",
    ),
    Mutation(
        "T29", "module",
        '    if not holders:\n        if is_dead_evidence(cands):',
        '    if not holders:\n        if ev.claim_read is not None:\n            return claim_verdict(ev.claim_read)\n        if is_dead_evidence(cands):',
        "the claim block outranks session evidence and can mask a lane's death (B7)",
    ),
    Mutation(
        "T30", "module",
        '            if ev.claim_read is not None:\n                return claim_verdict(ev.claim_read)\n',
        '            return claim_verdict(ev.claim_read or ClaimRead())\n',
        "the None guard is gone, so every session abstention becomes a claim abstention",
    ),
    Mutation(
        "T43", "module",
        '        if _bound_pid_field_re().search(pid_head):\n            return "?"',
        '        if False:\n            return "?"',
        "a `pid=` field that is PRESENT but unparseable (a FOREIGN / hand-edited verdict "
        "file, a restored state dir, or a future producer — NOT the shipped writer, which "
        "refuses a non-numeric `--pid`) is collapsed into \"no pid at all\", so the verdict "
        "is ADOPTED with the binding never checked — the binding table's DROP row published "
        "as its ADOPT row, one surface over from the census's column 11",
    ),
    Mutation(
        "T43", "module",
        '    if within is False:',
        '    if False:',
        "a verdict naming ANOTHER incarnation is adopted, so a previous dispatch's "
        "`finished` is published as this lane's — a false PASS over work nobody "
        "re-dispatches (the appended-log case)",
    ),
    Mutation(
        "T44", "module",
        '            lr.verdict_line_pid = parse_bound_pid(raw)',
        '            pass',
        "the verdict FILE is never bound, so a `$log.lanebound` left by an earlier "
        "dispatch is a false PASS and outranks the fresh bound log line",
    ),
    Mutation(
        "T44", "module",
        '        if why and lr.verdict_source == "verdict-file":',
        '        if False:',
        "a dropped file verdict BLOCKS the lane's own correctly-bound log line",
    ),
    Mutation(
        "T45", "module",
        '        if why:\n            lr.detail = " | ".join(x for x in (lr.detail, why) if x)',
        '        if why:\n            lr.detail = why',
        "the drop reason CLOBBERS acquisition's facts, publishing a different fact than "
        "the true one (`absent:<path>` lost)",
    ),
    Mutation(
        "T43", "module",
        '    return pids[-1] if len(pids[-1]) <= 10 else "?"',
        '    return pids[-1]',
        "the cap is gone, so an unusable pid token falls through to the FALLBACK guard: "
        "the drop reason becomes invalid-bound-verdict-pid instead of unbound-bound-verdict "
        "(and but for that guard, int() would raise out of gather_log_lane)",
    ),
    Mutation(
        "T49", "module",
        '    if not 1 <= len(fields) <= 3 or not all(f.isascii() and f.isdigit() for f in fields):',
        '    if not 1 <= len(fields) <= 3 or not all(f.isdigit() for f in fields):',
        "a non-ASCII digit passes .isdigit() and raises in int(), where _cpu_time_cs' "
        "contract is None on an unreadable read (the Mac `ps` path)",
    ),    Mutation(
        "T46", "module",
        '            if lr.verdict:',
        '            if False:',
        "the census seam does not enforce the binding, so the fleet-wide surface stays "
        "fail-open on a previous dispatch's verdict",
    ),
    Mutation(
        "T47", "module",
        '                 and lr.transcript_grew is not True)',
        '                 and lr.transcript_grew is None)',
        "a NEGATIVE byte delta is read as a FLAT reading instead of a broken one, so a log "
        "that was just truncated or rotated freezes a lane that is working",
    ),
    Mutation(
        "T48", "module",
        '                return tok if (tok.isascii() and tok.isdigit() and len(tok) <= 10) else "?"',
        '                return tok if (tok.isascii() and tok.isdigit()) else "?"',
        "the digit cap is gone, so an out-of-range row pid reaches int() BEFORE `_bind_verdict` "
        "decides and raises ValueError (the 4300-digit conversion limit), taking the whole "
        "census run down after printing only the rows before it",
    ),
    Mutation(
        "T48", "module",
        '                return tok if (tok.isascii() and tok.isdigit() and len(tok) <= 10) else "?"',
        '                return tok if (tok.isascii() and tok.isdigit() and len(tok) <= 10) else ""',
        "a col-11 pid that is PRESENT but unusable is collapsed into \"absent\", so the census "
        "takes the ADOPT arm and publishes a verdict whose binding was never checked — the "
        "fail-open the col-11 rule exists to close",
    ),
    Mutation(
        "T48", "module",
        '                    note = "bound-verdict-without-pid source=census"',
        '                    note = ""',
        "the census adopts an unbound 10-column row SILENTLY, so the fifth rule of the "
        "binding table is false on the fleet-wide surface",
    ),
    Mutation(
        "T43", "module",
        '    if not (line_pid.isascii() and line_pid.isdigit() and len(line_pid) <= 10):',
        '    if False:',
        "a caller that bypasses `parse_bound_pid` hands a non-numeric token to int(), so "
        "the drop becomes a ValueError out of `gather_log_lane`",
    ),
    # ── the 2026-11-04 review round: `rc=na` is not completion evidence ─────────────
    Mutation(
        "T37", "module",
        '                if lr.rc == "na":',
        '                if False and lr.rc == "na":',
        "the `rc=na` corroboration is dropped, so `watch` mode's unconditional token — the "
        "shape the fleet's ONLY launcher writes for every lane — is no longer required to "
        "be witnessed by the caller's rc line",
    ),
    Mutation(
        "T37", "module",
        '                    if lr.runner_rc != "0":',
        '                    if False:',
        "the launcher's NON-ZERO rc is ignored, so a crashed / OOM-killed / "
        "watchdog-killed lane publishes `finished` — the false PASS over lost work the "
        "whole rc conjunct exists to remove",
    ),
    Mutation(
        "T37", "module",
        'globals()["_BOUND_LINE_RE"] = _re.compile(r"\\[lane-bound\\]\\s+VERDICT\\b")',
        'globals()["_BOUND_LINE_RE"] = _re.compile(r"\\[lane-bound\\]\\s+VERDICT\\b.*?\\bverdict=([a-z][a-z-]*)")',
        "the locator requires a MATCHABLE token again, so an UNMATCHABLE final marker "
        "(uppercase / absent / spaced token) is never found and the previous recognised "
        "verdict is silently promoted",
    ),
    Mutation(
        "T46", "module",
        '            verdict_pid = _pidcol(10)',
        '            verdict_pid = _num(10)',
        "a PRESENT-but-unusable col 11 collapses to \"absent\", so the census ADOPTS a "
        "previous dispatch's verdict that `gather_log_lane` drops",
    ),
    Mutation(
        "T50", "module",
        'LOG_STATES = ("working", "frozen", "finished", "no-verdict", "dead", "unknown")',
        'LOG_STATES = ("working", "frozen", "finished", "no-verdict", "dead", "unknown", "gone")',
        "the log-state vocabulary grows silently, breaking every consumer and the doc's "
        "disjointness claim while the whole suite stays green",
    ),
]


def run_tests(only=None):
    passed = 0
    failed = 0
    for name, fn in TESTS:
        if only and name.split()[0] != only:
            continue
        try:
            fn()
        except Exception as exc:  # noqa: BLE001 - a test runner reports everything
            failed += 1
            print("  FAIL %s" % name)
            print("       %s: %s" % (exc.__class__.__name__, exc))
        else:
            passed += 1
            print("  ok   %s" % name)
    print("PASS=%d FAIL=%d" % (passed, failed))
    return failed == 0 and passed > 0


def _mutated_env(mut):
    tmp = tempfile.mkdtemp(prefix="liv-mutant-")
    if mut.target == "lib":
        with open(LIB_PATH, "r", encoding="utf-8") as fh:
            src = fh.read()
        if src.count(mut.old) != 1:
            raise SystemExit("mutation anchor not unique in %s (%d hits):\n%s"
                             % (LIB_PATH, src.count(mut.old), mut.old))
        os.makedirs(os.path.join(tmp, "lib"))
        out = os.path.join(tmp, "lib", "pid-identity.sh")
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(src.replace(mut.old, mut.new, 1))
        env = {"LIVENESS_MODULE": MODULE_PATH, "PI_PID_IDENTITY_LIB": out,
               "LIVENESS_ONLY": mut.test_name}
    else:
        with open(MODULE_PATH, "r", encoding="utf-8") as fh:
            src = fh.read()
        if src.count(mut.old) != 1:
            raise SystemExit("mutation anchor not unique in %s (%d hits):\n%s"
                             % (MODULE_PATH, src.count(mut.old), mut.old))
        out = os.path.join(tmp, "liveness.py")
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(src.replace(mut.old, mut.new, 1))
        env = {"LIVENESS_MODULE": out, "PI_PID_IDENTITY_LIB": LIB_PATH,
               "LIVENESS_ONLY": mut.test_name}
    return tmp, out, env


def _mutation_verdict(returncode: int, body: str) -> bool:
    """Is this mutation CAUGHT? Only if the paired test RAN and FAILED.

    ⛔ `returncode != 0` is NOT the test: ``run_tests`` also exits 1 when the
    filter matched nothing at all (``PASS=0 FAIL=0``), so a renamed test id — or a
    typo in the map — would report every mutation CAUGHT while verifying nothing.
    The runner publishes its own summary line, so the summary is the verdict.
    """
    if returncode == 0:
        return False
    for line in body.splitlines():
        m = re.match(r"\s*PASS=(\d+) FAIL=(\d+)\s*$", line)
        if m:
            return int(m.group(2)) > 0
    return False


def run_mutations():
    print("── MUTATION EVIDENCE — each mutation must make its paired test RED ──")
    print("   (the mutated file is written to a temp dir; the real source is never touched)\n")
    bad = 0
    for mut in MUTATIONS:
        tmp, out, env = _mutated_env(mut)
        try:
            proc = subprocess.run(
                [sys.executable, os.path.abspath(__file__)],
                env=dict(os.environ, **env),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            )
            body = proc.stdout.decode("utf-8", "replace")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        red = _mutation_verdict(proc.returncode, body)
        print("── %s mutation → %s ───────────────────────────────────────" % (mut.test_name, mut.why))
        for line in body.splitlines():
            print("   | %s" % line)
        if red:
            print("   ✅ RED (the paired test caught the defect, rc=%d)\n" % proc.returncode)
        else:
            bad += 1
            if "PASS=0" in body and "FAIL=0" in body:
                print("   ❌ NOT RUN — no test matched `%s`; this mutation verified NOTHING\n"
                      % mut.test_name)
            else:
                print("   ❌ NOT RED — the paired test did NOT catch its own defect\n")
    print("MUTATIONS=%d CAUGHT=%d MISSED=%d" % (len(MUTATIONS), len(MUTATIONS) - bad, bad))
    return bad == 0


def main(argv):
    if "--mutations" in argv:
        return 0 if run_mutations() else 1
    print("── #1178 liveness acceptance suite (%d tests) ──" % len(TESTS))
    return 0 if run_tests(os.environ.get("LIVENESS_ONLY")) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
