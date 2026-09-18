#!/usr/bin/env python3
"""tools/fleet/liveness.test.py — the #1178 acceptance suite.

Twelve mutation tests: every one is paired with a PRECISE source mutation that
reintroduces the defect the test exists to catch, so "the test fails without the
fix" is an EXECUTED claim rather than an asserted one. Two prior artifacts in
this repo claimed mutation evidence they did not have; this file makes the
evidence mechanical.

    python3 tools/fleet/liveness.test.py                # the 12 tests, green
    python3 tools/fleet/liveness.test.py --mutations     # each mutation, RED

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
import importlib.util
import json
import os
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


def ev(**kw):
    base = dict(sid="sid-1", now_ms=NOW_MS, jsonl_grew=False, jsonl_age_ms=H)
    base.update(kw)
    return liv.Evidence(**base)


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
                         tool=hung(tool_age_ms=31 * M, turn_active=False)))
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

    # (e) tool-silence shape: S = 20min, not load-scaled, and not 4h.
    v5 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=21 * M,
                         tool=hung(tool_updates=True, silence_age_ms=21 * M, tool_age_ms=21 * M)))
    check(v5.state == "wedged",
          "a streamed-then-silent tool past S=20min is wedged-eligible; got %s/%s" % (v5.state, v5.reason))
    v6 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=19 * M,
                         tool=hung(tool_updates=True, silence_age_ms=19 * M, tool_age_ms=19 * M)))
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

    v = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=30 * M, record=stale))
    check(v.state == "wedged",
          "a non-idle record stale past 72h must not immunise the lane; got %s/%s" % (v.state, v.reason))

    v2 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=30 * M, record=fresh))
    check(v2.state == "running-quiet",
          "a FRESH non-idle record vetoes wedged; got %s/%s" % (v2.state, v2.reason))

    v3 = liv.evaluate(ev(candidates=[C(1, "absent")], jsonl_grew=False, jsonl_age_ms=H, record=fresh))
    check(v3.state == "dead",
          "a record must NEVER veto dead — that re-creates the five-hour loss; got %s/%s" % (v3.state, v3.reason))

    v4 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=30 * M,
                         record=liv.Record(non_idle=True, updated_at=None)))
    check(v4.state == "running-quiet",
          "an unusable updatedAt keeps the veto (fail closed); got %s" % v4.state)

    v5 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=30 * M,
                         record=liv.Record(non_idle=False, updated_at=NOW_S - 3600)))
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
    v2 = liv.evaluate(ev(candidates=[C(1, "holder")], jsonl_age_ms=35 * M, tool=bash))
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
# The mutation map: each entry reintroduces the defect its test catches.
# ══════════════════════════════════════════════════════════════════════════
class Mutation:
    def __init__(self, test_name, target, old, new, why):
        self.test_name = test_name
        self.target = target          # "module" | "lib"
        self.old = old
        self.new = new
        self.why = why


MUTATIONS = [
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
        '    if cpu_attributable(tool) and tool.cpu_advanced:',
        '    if tool.cpu_advanced:',
        "CPU-flatness of a non-attributable tool (nested `task`) arms the kill (C8)",
    ),
    Mutation(
        "T12", "module",
        '    if not ev.ps_ok:\n'
        '        return Verdict("unknown", "ps-unreadable")\n',
        '',
        "the ps-availability guard is removed, so a failed read falls into the dead path (C3)",
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
        red = proc.returncode != 0
        print("── %s mutation → %s ───────────────────────────────────────" % (mut.test_name, mut.why))
        for line in body.splitlines():
            print("   | %s" % line)
        if red:
            print("   ✅ RED (the paired test caught the defect, rc=%d)\n" % proc.returncode)
        else:
            bad += 1
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
