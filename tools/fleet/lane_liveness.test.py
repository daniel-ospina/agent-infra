#!/usr/bin/env python3
"""tools/fleet/lane_liveness.test.py — hermetic suite for the scheduled report.

Shaped like ``scripts/fleet-cost-weekly.test.sh`` (CLEAN / TRIP / DEDUP /
DRY-RUN / rc=2) plus the legs this surface adds:

    CLEAN       a live fleet does not trip and makes no gh call
    TRIP        a dead lane escalates (gh issue CREATE with the lane named)
    DEDUP       a second trip with an OPEN issue comments, never re-creates
    DRY-RUN     a dead lane + --dry-run prints and signals, but never calls gh
    ENV-ERROR   a corrupt store is exit 2, no issue (§5)
    STALE-DEAD  a dead lane quiet past the reaper's idle proof is REPORTED,
                never escalated (the retired-pane noise class)
    CHILD-EXCL  a task child's newer record on the parent's workspace does not
                become the lane's verdict
    TURN-BOUNDARY a lane whose transcript ended is `running-quiet` however long
                it rests (short of the 24h retirement proof; this fixture's row
                reason is `turn-ended`, but the emitted POLICY sentence asserts
                only the state, since three paths reach it), while a
                lane frozen with an OPEN turn is still `wedged` — the #1254
                contract at the report layer
    COMPACTION    a lane whose last transcript entry is a `compaction` abstains
                (`unknown`/`tail-after-compaction`), never a decided turn (#1254 P1)

RED CONTROL (the part fleet-cost-weekly.test.sh has no equivalent of) — a green
suite is only a pin if it can FAIL. Eight mutations, each run against the leg
that must catch it (six mutate the report; two mutate the CLASSIFIER it
consumes, which is the seam #1254 actually broke):
  * escalate every state        → CLEAN must go red
  * escalate nothing            → TRIP must go red
  * drop the child exclusion    → CLEAN must go red
  * drop the open-workspace filter → CLOSED-WORKSPACE must go red
  * drop the turn-ended guard   → TURN-BOUNDARY must go red
  * compaction tail stops abstaining → COMPACTION must go red
  * policy text loses the 24h carve-out → TURN-BOUNDARY must go red
  * policy text names one reason for a state three paths reach → TURN-BOUNDARY must go red
A mutation the suite does not catch is reported as a suite failure.

Zero-dep by construction: python3 + bash only. Every input is a temp fixture;
``ps``/``date`` are hermetic shims and ``gh`` is a stub, so nothing touches the
real fleet, the store, or the network.

    python3 tools/fleet/lane_liveness.test.py
    python3 tools/fleet/lane_liveness.test.py --red-control   # mutation evidence
"""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_PATH = os.path.normpath(os.path.join(HERE, "lane_liveness.py"))
LIVENESS_PATH = os.path.normpath(os.path.join(HERE, "liveness.py"))
LIB_PATH = os.path.normpath(os.path.join(HERE, "..", "..", "scripts", "lib", "pid-identity.sh"))

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print("  ✅ %s" % msg)


def bad(msg):
    global FAIL
    FAIL += 1
    print("  ❌ %s" % msg)


def assert_eq(got, want, msg):
    if got == want:
        ok(msg)
    else:
        bad("%s (got: %r, want: %r)" % (msg, got, want))


def assert_contains(haystack, needle, msg):
    if needle in haystack:
        ok(msg)
    else:
        bad("%s (missing: %r)" % (msg, needle))


def assert_not_contains(haystack, needle, msg):
    if needle not in haystack:
        ok(msg)
    else:
        bad("%s (unexpected: %r)" % (msg, needle))


# ── clock + fixtures ─────────────────────────────────────────────────────
NOW_S = 1_789_000_000
NOW_MS = NOW_S * 1000
PROBE_EPOCH = 1_760_000_000
PROBE_LSTART = "Thu Sep 18 14:40:00 2026"

WS_ALIVE = "11111111-1111-4111-8111-111111111111"
WS_DEAD = "22222222-2222-4222-8222-222222222222"
WS_STALE = "33333333-3333-4333-8333-333333333333"
SID_ALIVE = "aaaaaaaa-0000-4000-8000-000000000001"
SID_DEAD = "bbbbbbbb-0000-4000-8000-000000000002"
SID_STALE = "cccccccc-0000-4000-8000-000000000003"
SID_CHILD = "dddddddd-0000-4000-8000-000000000004"
PID_ALIVE = 1111
PID_DEAD = 2222
PID_STALE = 3333
PID_CHILD = 4444
WS_TURN_DONE = "44444444-4444-4444-8444-444444444444"
WS_TURN_OPEN = "55555555-5555-4555-8555-555555555555"
SID_TURN_DONE = "eeeeeeee-0000-4000-8000-000000000005"
SID_TURN_OPEN = "ffffffff-0000-4000-8000-000000000006"
PID_TURN_DONE = 5555
PID_TURN_OPEN = 6666

PS_SHIM = """#!/usr/bin/env bash
[ "${1:-}" = "-axo" ] || exit 1
echo x >> "@COUNT@"
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

GH_STUB = """#!/usr/bin/env bash
echo "$*" >> "${GH_LOG:?}"
case "$1" in
  issue) shift
    case "$1" in
      list) echo "${GH_EXISTING:-[]}" ;;
      create) echo "https://github.com/mock/issue/7" ;;
      comment) echo ok ;;
    esac ;;
esac
"""


def ps_row(pid, lstart=PROBE_LSTART, stat="S", cmd="/usr/local/bin/pi"):
    return "%d 1 %d ttys001 %s %s 1234 %s" % (pid, pid, lstart, stat, cmd)


def record(sid, workspace, pid, *, updated_at, non_idle=True, cwd="/tmp/lane"):
    return {
        "sessionId": sid,
        "workspaceId": workspace,
        "surfaceId": workspace,
        "pid": pid,
        "pidStartSeconds": PROBE_EPOCH,
        "cwd": cwd,
        "startedAt": updated_at - 3600,
        "updatedAt": updated_at,
        "agentLifecycle": "running" if non_idle else "idle",
        "runtimeStatus": "running" if non_idle else "idle",
        "priorProcessGenerations": [],
    }


class Fixture:
    """A whole hermetic fleet: store, sessions, children, workspaces, gh stub."""

    def __init__(self, lanes, *, ps_rows=None, open_workspaces=None):
        """lanes: list of (label, workspace, sid, recorder-dict-for-store).

        ``open_workspaces`` is the set of workspace UUIDs cmux has OPEN (the
        population filter); ``None`` means "all fixture lanes are open".
        """
        self.dir = tempfile.mkdtemp(prefix="lane-liv-test-")
        self.lanes = lanes
        sessions = {}
        for _label, _ws, sid, rec in lanes:
            sessions[sid] = rec
        store = {"version": 1, "sessions": sessions}
        self.store = os.path.join(self.dir, "pi-hook-sessions.json")
        with open(self.store, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(store))

        self.sessions_dir = os.path.join(self.dir, "sessions")
        os.makedirs(self.sessions_dir, exist_ok=True)

        self.task_sessions = os.path.join(self.dir, "task-sessions")
        os.makedirs(os.path.join(self.task_sessions, SID_CHILD), exist_ok=True)

        self.log = os.path.join(self.dir, "lane-liveness.log")
        self.gh_log = os.path.join(self.dir, "gh.log")

        self.cmux_state = os.path.join(self.dir, "session-com.cmuxterm.app.json")
        if open_workspaces is None:
            open_workspaces = set(ws for _label, ws, _sid, _rec in lanes)
        with open(self.cmux_state, "w", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "version": 1,
                "windows": [{"tabManager": {
                    "workspaces": [{"workspaceId": ws} for ws in sorted(open_workspaces)]
                }}],
            }))

        # probe shims
        src = os.path.join(self.dir, "ps-source")
        with open(src, "w", encoding="utf-8") as fh:
            fh.write("\n".join(ps_rows if ps_rows is not None else [ps_row(PID_ALIVE)]) + "\n")
        self.ps_count = os.path.join(self.dir, "ps-count")
        ps = os.path.join(self.dir, "ps")
        with open(ps, "w", encoding="utf-8") as fh:
            fh.write(PS_SHIM.replace("@SOURCE@", src).replace("@COUNT@", self.ps_count))
        os.chmod(ps, 0o755)
        look = os.path.join(self.dir, "date.lookup")
        with open(look, "w", encoding="utf-8") as fh:
            fh.write("%s\t%d\n" % (PROBE_LSTART, PROBE_EPOCH))
        dt = os.path.join(self.dir, "date")
        with open(dt, "w", encoding="utf-8") as fh:
            fh.write(DATE_SHIM.replace("@LOOKUP@", look))
        os.chmod(dt, 0o755)
        self.ps, self.dt = ps, dt

        gh = os.path.join(self.dir, "gh")
        with open(gh, "w", encoding="utf-8") as fh:
            fh.write(GH_STUB)
        os.chmod(gh, 0o755)
        self.gh = gh

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def run_report(fx, *args, module=None, env_extra=None, dry_run=False):
    """Run the driver against the fixture; returns (rc, stdout, gh_calls)."""
    module = module or os.environ.get("LANE_LIVENESS_MODULE") or MODULE_PATH
    cmd = [sys.executable, module,
           "--store", fx.store,
           "--sessions-dir", fx.sessions_dir,
           "--task-sessions", fx.task_sessions,
           "--cmux-state", fx.cmux_state,
           "--log", fx.log,
           "--repo", "test-owner/agent-infra",
           "--gh-bin", fx.gh,
           "--now", str(NOW_MS)]
    if dry_run:
        cmd.append("--dry-run")
    cmd.extend(args)
    env = dict(os.environ)
    # Exercise the one-read-per-pass PS cache on every leg: no inherited PS_BIN,
    # the wrapper installed by the driver, the shim named as the real binary.
    env.pop("PS_BIN", None)
    env.pop("LANE_LIVENESS_PS_CACHE", None)
    env.update({
        "LANE_LIVENESS_PS_REAL": fx.ps,
        "DATE_BIN": fx.dt,
        "PI_PID_IDENTITY_LIB": LIB_PATH,
        "GH_LOG": fx.gh_log,
    })
    env.update(env_extra or {})
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    out = proc.stdout.decode("utf-8", "replace")
    gh_calls = ""
    if os.path.exists(fx.gh_log):
        with open(fx.gh_log, "r", encoding="utf-8") as fh:
            gh_calls = fh.read()
    return proc.returncode, out, gh_calls


def live_lane():
    return ("Live lane", WS_ALIVE, SID_ALIVE,
            record(SID_ALIVE, WS_ALIVE, PID_ALIVE, updated_at=NOW_S, cwd="/tmp/lane-live"))


def dead_lane():
    return ("Dead lane", WS_DEAD, SID_DEAD,
            record(SID_DEAD, WS_DEAD, PID_DEAD, updated_at=NOW_S, cwd="/tmp/lane-dead"))


def stale_lane():
    return ("Stale lane", WS_STALE, SID_STALE,
            record(SID_STALE, WS_STALE, PID_STALE, updated_at=NOW_S - 30 * 3600,
                   cwd="/tmp/lane-stale"))


def child_record():
    # A child on the LIVE lane's workspace, NEWER than the lane's own record and
    # with a pid that is gone: if the exclusion is dropped this shadows the lane
    # and the clean fleet trips.
    return (SID_CHILD, record(SID_CHILD, WS_ALIVE, PID_CHILD, updated_at=NOW_S + 600,
                              cwd="/tmp/lane-child"))


# ── #1254 fixtures: a resting lane and a mid-turn lane, both frozen ──────
def turn_done_lane():
    return ("turn-done", WS_TURN_DONE, SID_TURN_DONE,
            # non_idle=False so the record veto does NOT fire and the ladder runs.
            record(SID_TURN_DONE, WS_TURN_DONE, PID_TURN_DONE, updated_at=NOW_S,
                   non_idle=False, cwd="/tmp/turn-done"))


def turn_open_lane():
    return ("turn-open", WS_TURN_OPEN, SID_TURN_OPEN,
            record(SID_TURN_OPEN, WS_TURN_OPEN, PID_TURN_OPEN, updated_at=NOW_S,
                   non_idle=False, cwd="/tmp/turn-open"))


def msg_entry(role, **msg):
    base = {"role": role}
    base.update(msg)
    return {"type": "message", "message": base}


def write_transcript(fx, sid, cwd, entries, *, age_s=1800):
    """Write a session JSONL where session_file_for() will find it, frozen."""
    d = os.path.join(fx.sessions_dir, "--%s--" % cwd.lstrip("/").replace("/", "-"))
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "2026-01-01T00-00-00-000Z_%s.jsonl" % sid)
    with open(path, "w", encoding="utf-8") as fh:
        for e in entries:
            fh.write(json.dumps(e) + "\n")
    os.utime(path, (NOW_S - age_s, NOW_S - age_s))
    return path


# ══════════════════════════════════════════════════════════════════════════
# The legs
# ══════════════════════════════════════════════════════════════════════════
def leg_clean(module=None):
    print("── CLEAN — a live fleet does not trip ──")
    fx = Fixture([live_lane()], ps_rows=[ps_row(PID_ALIVE)])
    try:
        # The child's record is newer AND dead-pid: only the child exclusion
        # keeps this clean.
        sessions = json.load(open(fx.store))
        sessions["sessions"][SID_CHILD] = child_record()[1]
        with open(fx.store, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(sessions))
        rc, out, gh = run_report(fx, module=module)
        assert_eq(rc, 0, "live fleet exits 0")
        assert_contains(out, "PASS", "clean run logs PASS")
        if gh:
            bad("clean fleet called gh: %s" % gh)
        else:
            ok("clean fleet makes no gh call")
        with open(fx.log, "r", encoding="utf-8") as fh:
            log = fh.read()
        assert_contains(log, "PASS", "durable log carries the PASS footer")
        # One `ps` read for the whole pass: several lanes are probed (the live
        # lane plus the shadowing child record), the shim must run exactly once.
        with open(fx.ps_count, "r", encoding="utf-8") as fh:
            reads = len([l for l in fh.read().splitlines() if l.strip()])
        assert_eq(reads, 1, "one `ps` read per pass (the cache wrapper collapses ~N probe forks)")
        if os.path.exists(fx.gh_log):
            bad("clean fleet wrote a gh log")
        else:
            ok("clean fleet never invoked the gh stub")
    finally:
        fx.close()


def leg_trip(module=None):
    print("── TRIP — a dead lane escalates ──")
    fx = Fixture([live_lane(), dead_lane()], ps_rows=[ps_row(PID_ALIVE)])
    try:
        rc, out, gh = run_report(fx, module=module)
        assert_eq(rc, 1, "a dead lane exits 1")
        assert_contains(gh, "issue create", "the dead lane opened an issue")
        assert_contains(gh, "lane-dead", "the issue body names the dead lane")
        assert_contains(out, "incarnations-absent", "the report carries the evidence")
        assert_contains(out, "2222:absent", "the report names the absent incarnation")
        if "lane-live" in gh and "lane-dead" not in gh:
            bad("only the dead lane may be escalated")
        else:
            ok("the live lane is not escalated")
    finally:
        fx.close()


def leg_dedup(module=None):
    print("── DEDUP — an open issue is commented, never re-created ──")
    fx = Fixture([live_lane(), dead_lane()], ps_rows=[ps_row(PID_ALIVE)])
    try:
        rc, _out, gh = run_report(fx, module=module,
                                  env_extra={"GH_EXISTING": '[{"number": 42}]'})
        assert_eq(rc, 1, "a dead lane still exits 1")
        assert_contains(gh, "issue comment", "dedup commented on the open issue")
        if "issue create" in gh:
            bad("dedup must NOT create a second issue")
        else:
            ok("dedup never creates while an issue is open")
    finally:
        fx.close()


def leg_dry_run(module=None):
    print("── DRY-RUN — prints and signals, never calls gh ──")
    fx = Fixture([live_lane(), dead_lane()], ps_rows=[ps_row(PID_ALIVE)])
    try:
        rc, out, gh = run_report(fx, module=module, dry_run=True)
        assert_eq(rc, 1, "--dry-run still signals the escalation (exit 1)")
        assert_contains(out, "[dry-run] would file", "--dry-run announces the would-file")
        if gh:
            bad("--dry-run called gh: %s" % gh)
        else:
            ok("--dry-run makes no gh call")
    finally:
        fx.close()


def leg_env_error(module=None):
    print("── ENV-ERROR — a broken input is exit 2, never an issue ──")
    fx = Fixture([live_lane(), dead_lane()], ps_rows=[ps_row(PID_ALIVE)])
    try:
        with open(fx.store, "w", encoding="utf-8") as fh:
            fh.write("{not json")
        rc, out, gh = run_report(fx, module=module)
        assert_eq(rc, 2, "a corrupt store exits 2")
        assert_contains(out, "no verdict, no issue", "the env error is logged distinctly")
        if gh:
            bad("env error called gh: %s" % gh)
        else:
            ok("env error files no issue")

        # A bad flag is also a usage error (argparse), not an escalation.
        rc2, _o2, gh2 = run_report(fx, "--bogus", module=module)
        assert_eq(rc2, 2, "an unknown flag exits 2")
        if gh2:
            bad("usage error called gh: %s" % gh2)
        else:
            ok("usage error files no issue")
    finally:
        fx.close()


def leg_stale_dead(module=None):
    print("── STALE-DEAD — a retired pane is reported, never escalated ──")
    fx = Fixture([live_lane(), stale_lane()], ps_rows=[ps_row(PID_ALIVE)])
    try:
        rc, out, gh = run_report(fx, module=module)
        assert_eq(rc, 0, "a dead lane quiet past the reaper's idle proof does not escalate")
        assert_contains(out, "**dead**", "the stale dead lane is still REPORTED (never disappears)")
        assert_contains(out, "withheld from escalation", "the report explains the withholding")
        if gh:
            bad("a retired pane called gh: %s" % gh)
        else:
            ok("retired pane files no issue")
    finally:
        fx.close()


def leg_ps_cache(module=None):
    print("── PS-CACHE — one `ps` read per pass, N without the wrapper ──")
    fx = Fixture([live_lane()], ps_rows=[ps_row(PID_ALIVE)])
    try:
        rc, _out, _gh = run_report(fx, module=module)
        assert_eq(rc, 0, "cached pass exits 0")
        with open(fx.ps_count, "r", encoding="utf-8") as fh:
            reads = len([l for l in fh.read().splitlines() if l.strip()])
        assert_eq(reads, 1, "the wrapper collapses the pass to ONE `ps` read")
        # Negative control: an explicit PS_BIN (the documented override) disables
        # the cache, so the shim must be forked once per probe. Without this the
        # 'one read' assertion would also pass if the probes were simply not
        # running.
        os.remove(fx.ps_count)
        rc2, _o2, _g2 = run_report(fx, module=module, env_extra={"PS_BIN": fx.ps})
        assert_eq(rc2, 0, "uncached pass still exits 0")
        with open(fx.ps_count, "r", encoding="utf-8") as fh:
            reads2 = len([l for l in fh.read().splitlines() if l.strip()])
        if reads2 > 1:
            ok("without the cache the identity probes fork `ps` per probe (%d reads)" % reads2)
        else:
            bad("uncached pass read `ps` %d time(s) — the control does not discriminate" % reads2)
    finally:
        fx.close()


def leg_closed_workspace(module=None):
    print("── CLOSED-WORKSPACE — a retired pane is not a lane ──")
    # The dead lane's workspace is NOT in cmux's open set (a superseded pane),
    # while its record is fresh. Without the open-workspace filter it escalates.
    fx = Fixture([live_lane(), dead_lane()], ps_rows=[ps_row(PID_ALIVE)],
                 open_workspaces={WS_ALIVE})
    try:
        rc, out, gh = run_report(fx, module=module)
        assert_eq(rc, 0, "a closed workspace with a fresh dead record does not escalate")
        assert_contains(out, "lane-live", "the open lane is still reported")
        if "lane-dead" in out:
            bad("a closed workspace must not be reported as a lane")
        else:
            ok("the closed workspace is filtered out of the population")
        if gh:
            bad("a closed workspace called gh: %s" % gh)
        else:
            ok("a closed workspace files no issue")
    finally:
        fx.close()


def leg_turn_boundary(module=None):
    print("── TURN-BOUNDARY — resting is not wedged; an open turn still is (#1254) ──")
    fx = Fixture([turn_done_lane(), turn_open_lane()],
                 ps_rows=[ps_row(PID_TURN_DONE), ps_row(PID_TURN_OPEN)])
    try:
        # Both transcripts are frozen 30 min (past S = 20 min, inside the 24h
        # idle proof). The ONLY difference is the turn boundary.
        write_transcript(fx, SID_TURN_DONE, "/tmp/turn-done",
                         [msg_entry("assistant", stopReason="stop",
                                    content=[{"type": "text", "text": "done"}])])
        write_transcript(fx, SID_TURN_OPEN, "/tmp/turn-open",
                         [msg_entry("assistant", stopReason="toolUse",
                                    content=[{"type": "toolCall", "name": "bash",
                                              "id": "call_00_OPEN"}])])
        rc, out, gh = run_report(fx, "--json", module=module)
        assert_eq(rc, 0, "neither lane escalates (both have a live holder)")
        parsed = json.loads(out.splitlines()[0])
        verdicts = {l["lane"]: l for l in parsed["lanes"]}
        done = verdicts.get("turn-done", {})
        assert_eq(done.get("state"), "running-quiet",
                  "a turn-ended lane is running-quiet, never wedged")
        assert_eq(done.get("reason"), "turn-ended", "the reason names the turn boundary")
        if "terminal stopReason=stop" in out:
            ok("the report's evidence names the terminal stopReason")
        else:
            bad("the report must say WHY the lane is resting (terminal stopReason absent)")
        opened = verdicts.get("turn-open", {})
        assert_eq(opened.get("state"), "wedged", "a frozen OPEN turn is still wedged")
        assert_eq(opened.get("reason"), "turn-open:pending-tool-call",
                  "the wedged reason names the open turn")
        if "call_00_OPEN" in out:
            ok("the report names the unanswered call")
        else:
            bad("the wedged row must name the open call")
        assert_eq(parsed["counts"].get("wedged"), 1,
                  "exactly one wedged lane: the open turn, not the resting one")
        # P2: the emitted policy text must say what the code does — a resting
        # lane is running-quiet only SHORT OF the 24h retirement proof (past it
        # the `idle`/`jsonl-old` branch returns first).
        assert_contains(out, "short of the 24h retirement proof",
                        "the policy text names the retirement-proof carve-out")
        # #1273: the policy sentence must assert the STATE alone — three paths
        # return `running-quiet` for a turn-ended lane (`quiet-within-bound`
        # inside the stream bound, `turn-ended` past it, `record-non-idle-fresh`
        # while the input-consumption veto holds), so naming ONE reason for it
        # was false. The row's own `reason` column is what names the path.
        assert_not_contains(out, "`running-quiet`/`turn-ended`",
                            "the policy text does not name one reason for a state three paths reach (#1273)")
        if gh:
            bad("a live-holder wedge must not escalate: %s" % gh)
        else:
            ok("neither verdict escalates (dead-only policy)")
    finally:
        fx.close()


def leg_compaction(module=None):
    print("── COMPACTION — a between-turns summary abstains, never decides (#1254 P1) ──")
    fx = Fixture([turn_done_lane(), turn_open_lane()],
                 ps_rows=[ps_row(PID_TURN_DONE), ps_row(PID_TURN_OPEN)])
    try:
        # Both transcripts are frozen 30 min and BOTH end with a `compaction`
        # entry: pi writes it between turns, so it is not evidence the previous
        # turn ended. Measured over the real corpus: 483 compactions, 477
        # followed by a message entry and 357 of those an open assistant/toolUse.
        write_transcript(fx, SID_TURN_DONE, "/tmp/turn-done",
                         [msg_entry("assistant", stopReason="stop",
                                    content=[{"type": "text", "text": "done"}]),
                          {"type": "compaction", "summary": "…"}])
        write_transcript(fx, SID_TURN_OPEN, "/tmp/turn-open",
                         [msg_entry("assistant", stopReason="toolUse",
                                    content=[{"type": "toolCall", "name": "bash",
                                              "id": "call_00_OPEN"}]),
                          {"type": "compaction", "summary": "…"}])
        rc, out, gh = run_report(fx, "--json", module=module)
        assert_eq(rc, 0, "no lane escalates: an abstention is not a death witness")
        parsed = json.loads(out.splitlines()[0])
        verdicts = {l["lane"]: l for l in parsed["lanes"]}
        for label in ("turn-done", "turn-open"):
            v = verdicts.get(label, {})
            assert_eq(v.get("state"), "unknown",
                      "%s: a compaction tail is an abstention, never wedged" % label)
            assert_eq(v.get("reason"), "tail-after-compaction",
                      "%s: the abstention names the compaction tail" % label)
        assert_eq(parsed["counts"].get("wedged", 0), 0,
                  "the open turn behind a compaction must NOT read wedged")
        assert_eq(parsed["counts"].get("unknown"), 2,
                  "both compaction-tailed lanes abstain")
        if gh:
            bad("an abstention must not escalate: %s" % gh)
        else:
            ok("abstention never escalates (dead-only policy)")
    finally:
        fx.close()


LEGS = [("CLEAN", leg_clean), ("TRIP", leg_trip), ("DEDUP", leg_dedup),
        ("DRY-RUN", leg_dry_run), ("ENV-ERROR", leg_env_error),
        ("STALE-DEAD", leg_stale_dead), ("CLOSED-WORKSPACE", leg_closed_workspace),
        ("PS-CACHE", leg_ps_cache), ("TURN-BOUNDARY", leg_turn_boundary),
        ("COMPACTION", leg_compaction)]


# ══════════════════════════════════════════════════════════════════════════
# The RED control — the suite must catch a broken report
# ══════════════════════════════════════════════════════════════════════════
class Mutation:
    def __init__(self, name, old, new, leg, want_rc, why, target="report"):
        self.name = name
        self.old = old
        self.new = new
        self.leg = leg
        self.want_rc = want_rc
        self.why = why
        self.target = target          # "report" | "classifier"


MUTATIONS = [
    Mutation(
        "escalate-every-state",
        'ESCALATE_STATES = frozenset({"dead"})',
        'ESCALATE_STATES = frozenset({"dead", "running-quiet"})',
        leg_clean, 1,
        "a report that trips on a live (running-quiet) fleet is caught by CLEAN",
    ),
    Mutation(
        "escalate-nothing",
        'ESCALATE_STATES = frozenset({"dead"})',
        'ESCALATE_STATES = frozenset()',
        leg_trip, 0,
        "a report that misses a dead lane is caught by TRIP",
    ),
    Mutation(
        "drop-child-exclusion",
        '        if not isinstance(rec, dict) or sid in children:',
        '        if not isinstance(rec, dict):',
        leg_clean, 1,
        "a child's newer record shadows its parent lane; CLEAN catches it",
    ),
    Mutation(
        "drop-open-workspace-filter",
        '        if open_ids is not None:',
        '        if False:',
        leg_closed_workspace, 1,
        "a retired/closed pane escalates again; CLOSED-WORKSPACE catches it",
    ),
    Mutation(
        "drop-turn-ended-protection",
        '    if not turn.stalled:\n'
        '        return Verdict("running-quiet", turn.reason, holder_pid=holder.pid, detail=turn.detail)\n',
        '    if False:\n'
        '        return Verdict("running-quiet", turn.reason, holder_pid=holder.pid, detail=turn.detail)\n',
        leg_turn_boundary, 0,
        "a resting lane reads wedged again at the report layer; TURN-BOUNDARY catches it (#1254)",
        target="classifier",
    ),
    Mutation(
        "compaction-tail-decides",
        '    if (last_entry is not None and isinstance(last_entry, dict)\n'
        '            and last_entry.get("type") == "compaction"):\n'
        '        return turn_from_entry(last_entry)\n',
        '',
        leg_compaction, 0,
        "a compaction tail falls through to the previous message, so a between-turns summary decides (#1254 P1)",
        target="classifier",
    ),
    Mutation(
        "policy-text-loses-the-carve-out",
        '        "rests short of the 24h retirement proof, so only a lane whose every "\n',
        '        "rests, so only a lane whose every "\n',
        leg_turn_boundary, 1,
        "the emitted policy text asserts a rule the code does not implement (no 24h carve-out, T13) (#1254 P2)",
        target="report",
    ),
    Mutation(
        "policy-text-names-one-reason-for-three-paths",
        '        "last turn ended reads `running-quiet` however long it "\n',
        '        "last turn ended reads `running-quiet`/`turn-ended` however long it "\n',
        leg_turn_boundary, 1,
        "the emitted policy text names ONE reason for a state three paths reach (#1273)",
        target="report",
    ),
]


def _mutant_dir(mut):
    tmp = tempfile.mkdtemp(prefix="lane-liv-mutant-")
    with open(LIVENESS_PATH, "r", encoding="utf-8") as fh:
        liv_src = fh.read()
    with open(MODULE_PATH, "r", encoding="utf-8") as fh:
        rep_src = fh.read()
    target_path = LIVENESS_PATH if mut.target == "classifier" else MODULE_PATH
    target_src = liv_src if mut.target == "classifier" else rep_src
    if target_src.count(mut.old) != 1:
        raise SystemExit("mutation anchor not unique in %s (%d hits):\n%s"
                         % (target_path, target_src.count(mut.old), mut.old))
    if mut.target == "classifier":
        liv_src = liv_src.replace(mut.old, mut.new, 1)
    else:
        rep_src = rep_src.replace(mut.old, mut.new, 1)
    with open(os.path.join(tmp, "liveness.py"), "w", encoding="utf-8") as fh:
        fh.write(liv_src)
    out = os.path.join(tmp, "lane_liveness.py")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(rep_src)
    return tmp, out


def run_red_control():
    print("── RED CONTROL — each mutation must make its paired leg RED ──\n")
    global PASS, FAIL
    caught = 0
    missed = 0
    saved_pass, saved_fail = PASS, FAIL
    for mut in MUTATIONS:
        tmp, out = _mutant_dir(mut)
        # Each leg prints its own ok/❌ lines; silence them and use the GLOBAL
        # counters delta to decide whether the leg went red.
        before_pass, before_fail = PASS, FAIL
        with contextlib.redirect_stdout(_Null()):
            try:
                mut.leg(module=out)
            except Exception as exc:  # noqa: BLE001
                print("leg raised: %s" % exc)
            leg_pass = PASS - before_pass
            leg_fail = FAIL - before_fail
        shutil.rmtree(tmp, ignore_errors=True)
        red = leg_fail > 0
        print("── %s → %s" % (mut.name, mut.why))
        print("   leg failures=%d (a leg assertion must fail), rc-hint=%d, leg passes=%d"
              % (leg_fail, mut.want_rc, leg_pass))
        if red:
            caught += 1
            print("   ✅ RED — the suite caught the broken report\n")
        else:
            missed += 1
            print("   ❌ NOT RED — the suite did NOT catch its own defect\n")
    PASS, FAIL = saved_pass, saved_fail
    print("RED-CONTROL mutations=%d caught=%d missed=%d" % (len(MUTATIONS), caught, missed))
    if missed:
        bad("RED control missed %d mutation(s)" % missed)
    else:
        ok("RED control caught every mutation")
    return missed == 0


class _Null:
    def write(self, _s):
        return 0

    def flush(self):
        return None


def main(argv):
    if "--red-control" in argv:
        return 0 if run_red_control() else 1
    print("── scheduled lane-liveness report — hermetic suite ──")
    print("   RED control is the same suite against a mutated report; run with")
    print("   --red-control (it is also run by default below).\n")
    for _name, fn in LEGS:
        fn()
    print("")
    run_red_control()
    print("")
    print("PASS=%d FAIL=%d" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
