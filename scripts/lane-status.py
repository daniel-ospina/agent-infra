#!/usr/bin/env python3
"""lane-status — multi-signal lane health. No single signal is definitive.

Signals combined (owner, 2026-09-25):
  1. SESSION file  — mtime/size DELTA over a sample window. The only reliable
                     liveness signal: the spinner animates while wedged.
  2. TRANSCRIPT    — the last 1-3 messages: tells WIP from DONE, which a
                     spinner cannot.
  3. UI            — the 'Working' indicator from cmux.
  4. CHILD         — does the lane have a sub-agent in flight, and is THAT
                     child alive? A parent waiting on a child writes nothing
                     to its own session file, so raw mtime reads "wedged" on a
                     lane that is working correctly. This is the HANG case.

The child signal is read from the parent's OWN transcript, which is the only
place it exists: a `subagent`/`task` toolCall with no matching toolResult is a
pending child, and the result's leading text is its verdict
("Agent timeout:", "Agent aborted:", "Agent failed:") .

Usage:
  lane-status.py                 # human table
  lane-status.py --json          # machine
  lane-status.py --sample 20     # seconds of file sampling (default 18)
"""
import json, os, re, subprocess, sys, time, glob, argparse
from collections import Counter

# ⛔ cmux IS NOT ON PATH FOR A LAUNCHD JOB. Measured 2026-10-12: the heartbeat's launchd
# environment carries NO PATH AT ALL (`launchctl print gui/$UID/com.tortoise.heartbeat-loop` shows
# only SSH_AUTH_SOCK). `sh_rc` runs every subprocess with `env=CMUX`, so with no PATH the
# `["cmux", ...]` spawn fails, `LIVE_READABLE` goes False, EVERY row is marked `degraded`, and
# `lane-actions.py` then REFUSES the snapshot — so `pr-doctor.py` classified 15 open PRs on every
# pass and could not dispatch one fix. Do not rely on an inherited PATH a daemon does not have:
# name the binary's directory explicitly. (Same failure class as the `gh` shim, #8246.)
_CMUX_BIN_DIRS = (
    "/Applications/cmux.app/Contents/Resources/bin",
    os.path.join(os.path.expanduser("~"), ".local", "bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
)
CMUX = dict(os.environ, CMUX_QUIET="1")
_present = [d for d in _CMUX_BIN_DIRS if os.path.isdir(d)]
if _present:
    CMUX["PATH"] = os.pathsep.join(_present + [CMUX.get("PATH", "")])
SD = os.path.expanduser("~/.pi/agent/sessions")
TASK_SD = os.path.expanduser("~/.pi/agent/task-sessions")
REG = os.path.expanduser("~/.pi/agent/state/lane-registry.tsv")

WORKING, WAITING, WIP_IDLE, DONE_IDLE, WEDGED, EMPTY, UNKNOWN, UNBOUND = (
    "WORKING", "WAITING-CHILD", "WIP-IDLE", "DONE-IDLE", "WEDGED", "EMPTY",
    "UNKNOWN", "UNBOUND")
CHILD_STUCK = "CHILD-STUCK"        # a persisted child gone quiet
WAITING_OVERDUE = "CHILD-OVERDUE"  # pending child past the harness's own silence bound
WAITING_OVERDUE = "CHILD-OVERDUE"  # pending child past the harness's own silence bound

TOOL_NAMES = ("subagent", "task")
# verdict prefixes pi writes into the toolResult text
RESULT_VERDICTS = ("Agent timeout:", "Agent aborted:", "Agent failed:", "Agent cut:")
# A third "parent writes nothing" case, alongside WAITING-CHILD: a direct tool call
# that is legitimately long. Observed live — lane `1 Capture write doors` ran
# `admin-merge.sh <PR>` with an explicit `timeout 3000s` and sat byte-identical for
# 38 minutes. The poll is bounded by the timeout DECLARED in the call, so a long
# tool is not mistaken for a wedge.
LONG_TOOL = "LONG-TOOL"
# A dispatch with no result older than this is ABANDONED, not pending — otherwise a
# call from days ago (whose result was never recorded) makes a healthy lane read
# CHILD-STUCK forever. Real children that run this long have already timed out.
ABANDON_S = 30 * 60          # == the harness's own in-flight bound (OVERDUE_S),
                              # plus a small margin.
                              # ⛔ WHAT THIS ANSWERS, NARROWED 2026-10-12. It used to mean "past
                              # this the child is DEAD, so its open call is a stale record" -- and
                              # that premise is FALSE (measured: three task children alive and
                              # running pytest at 2h26m, a child polling CI at 1h30m). A child
                              # outlives this whenever it keeps producing OUTPUT; the harness
                              # bound is on SILENCE, not on runtime. ABANDON_S now answers only
                              # its supportable question -- "may this record SUPPRESS an action
                              # verdict" (child_suppresses) -- and never "does the child exist".
                              # `pending_child` reports `abandoned=True` instead of erasing it.
SESSION_VERIFY_S = 30 * 60   # a session file nobody has written for this long is NOT verified
                              # as "the live session" -- resolve_session_ex says so out loud
                              # rather than asserting an idle lane off a dead id.

# Verdicts that tell a reader to ACT on a lane -- dispatch it, or check/kill it. A live
# signal must never be overridden BY one of these. WEDGED is the costly member: its
# instruction is to check the process, which invites a kill/respawn of a HEALTHY lane.
ACTION_VERDICTS = (DONE_IDLE, WIP_IDLE, WEDGED, CHILD_STUCK, WAITING_OVERDUE)
CHILD_SUPPRESSED = ACTION_VERDICTS   # back-compat alias; the set is no longer child-specific

# ── INBOUND-RECENCY IS A **PRIOR**, NOT A LIVENESS PROOF (owner 2026-10-11, corrected) ────────
# `cmux list-workspaces --json` gives, per workspace, `latest_submitted_at` + `latest_submitted_message`
# for the whole fleet in ONE call. Useful -- but ⛔ IT IS INBOUND. It is the last turn SUBMITTED TO the
# workspace, not output produced BY it. Inspecting the whole column shows every value is inbound: the
# orchestrator's is the heartbeat, `Tortoise markeitng`'s is the OWNER asking a question, `rail-4764`'s
# is a dispatch someone sent it. So it answers "when was this lane last TOLD something", NOT "is this
# lane producing". An earlier version of this file treated it as a liveness signal and let it veto any
# verdict; that was WRONG and is reverted here.
#
# WHAT IT IS GOOD FOR (the weaker, true claims):
#   1. STALENESS -- a lane whose last inbound is hours old AND which shows no output is genuinely
#      suspicious. That ESCALATES to a real check; it is never a WEDGED verdict on its own.
#   2. That work was recently ASSIGNED -- a fresh work order means "do not call this idle". This is
#      the case it was actually needed for: `2a Projection keys` read IDLE->WITHHELD on a work order
#      submitted 0.03h earlier, and acting on that would have interrupted live work.
#
# ⛔ WHAT ACTUAL LIVENESS USES: the lane's SESSION JSONL mtime/size (`stale`/`grew`, above). That is
# OUTPUT -- it advances when the lane works and stops when it stalls -- and it stays the primary signal.
# Inbound-recency is reported BESIDE it, never in place of it.
#
# ⛔ AND IT MUST NOT VETO THE SERIOUS VERDICTS. A fresh inbound is not proof of life, so it discounts
# only the IDLE family ("dispatch it") and NEVER WEDGED / CHILD-STUCK / CHILD-OVERDUE ("check the
# process", "a child is stuck"). Suppressing those on an INBOUND event would hide a real wedge -- and
# one of tonight's lanes, `tortoise-sweep`, was genuinely wedged.
# ⛔ NOT NAMED FOR LIVENESS. The correction that withdrew the over-claim ("`latest_submitted_at` is
# a liveness signal") is only as durable as the NAMES it leaves behind: a constant whose name says
# LIVE invites the next reader to re-derive exactly the claim this file spends thirty lines
# retracting. (The old identifier is deliberately not repeated here — `test_lane_status.py` asserts
# it is absent from this file, so a comment quoting it would fail the pin.) The bound is about how
# RECENT the inbound is, and nothing more.
INBOUND_FRESH_S = ABANDON_S    # == the harness's own in-flight bound: inside it, the lane was
                                # told something a legal turn ago, so "idle" is not a safe claim.
INBOUND_DISCOUNTS = (DONE_IDLE, WIP_IDLE)
# ⛔ ITS OWN VERDICT, NOT "WAITING-CHILD". The discount and the child prior are DIFFERENT
# observations -- "it was recently told something" vs "a child is in flight" -- and reusing the
# child label made the table assert a child that does not exist. MEASURED 2026-10-11:
# `2a Projection keys` read `WAITING-CHILD` with NO `child`, NO `pane_children` and NO `declared`;
# the label came from this discount, so a reader chasing an imaginary child could not see that the
# lane was in fact simply free. A suppression target must name the evidence that produced it.
WAITING_INBOUND = "RECENT-INBOUND"


def inbound_discounts_idle(verdict, inbound_age, stale_s=None):
    """Does a recent INBOUND event discount this verdict -- i.e. "do not call this idle"?

    Scoped to INBOUND_DISCOUNTS on purpose. An inbound event proves only that the lane was
    recently TOLD something, so it may stop us DISPATCHING to a lane that was just given work;
    it may not overrule a claim that the lane is stuck, which rests on the lane's own OUTPUT.

    `None` -- an unread timestamp -- ABSTAINS: a failed read must neither discount a verdict
    nor be read as staleness.

    ⛔ AND ONLY WHILE THE LANE HAS NOT WRITTEN SINCE. `stale_s` is the lane's OWN session-file age
    -- its output. When the output is NEWER than the inbound (`stale_s < inbound_age`), the lane has
    already ANSWERED what it was told: it took the work order, finished the turn, and is idle again,
    so the discount must NOT fire. MEASURED 2026-10-11 on `2a Projection keys`: inbound 27m old but
    its last write 25m old -- a COMPLETED turn ("Posted as 6114467601 on #6151") -- so the work
    order had been consumed and IDLE was correct. The rule without this check suppressed a genuinely
    free lane and mislabelled it as waiting on a child. `stale_s=None` (unread) does not fire the
    check either way: an unread output age is not evidence the inbound was consumed.
    """
    if inbound_age is None:
        return False
    if verdict not in INBOUND_DISCOUNTS:
        return False
    if inbound_age > INBOUND_FRESH_S:
        return False
    if stale_s is not None and stale_s < inbound_age:
        return False        # output is newer than the inbound: it was consumed, so IDLE stands
    return True


def told_but_silent(inbound_age, stale_s):
    """True when the lane was TOLD something AFTER it last produced output.

    ⛔ THIS IS THE **ACTION** SURFACE'S RULE, AND IT IS NOT `inbound_discounts_idle`. That one is
    the **CLAIM** surface's rule: a PRIOR, scoped to the IDLE family, never `WEDGED`, because an
    input event cannot prove a wedge resolved. This one is a **VETO** and it is
    verdict-INDEPENDENT: a lane that received work and has produced nothing since is not free
    capacity, whatever anyone believes about its state. A claim and an instruction are different
    speech acts, and keeping them in two functions is what stops a later change collapsing them
    into one. They are deliberately near each other so the contrast is visible.

    Why it exists (MEASURED 2026-10-11, four instances): the beat's IDLE set is decided by the
    Step-5 words layer -- JEV reads the lane's own LAST WORDS, which cannot know that a work order
    landed AFTER they were written. So `2a Projection keys` read `DONE_READY` from words emitted
    before a `WORK ORDER -- #8169` arrived 108s earlier, and the beat published `IDLE->1 WITHHELD
    2a Projection keys` -- an instruction to a human to hand work to a lane that already had it.
    Owner, verbatim: "Both of those were in the DO list telling me to act. Acting would have
    interrupted live work."

    `None` on EITHER side ABSTAINS (False). An unread inbound, or an unknown output age, is not
    evidence of silence; returning True on a failed read would exclude a lane on a fact nobody
    established. Same rule as everywhere else here: an unread signal is not a value.
    """
    if inbound_age is None or stale_s is None:
        return False
    return inbound_age < stale_s


def child_suppresses(verdict, declared, pane_kids, child, child_stale, abandon_s=None):
    """Should this verdict be suppressed to WAITING because the lane has a child?

    ⛔ THE LANE'S OWN TRANSCRIPT IS THE AUTHORITATIVE SOURCE, and this function exists because
    it was the one source nobody read. MEASURED 2026-10-11:
      * `parse_child_lines` matches `[task] child session <id> -> <dir>`. The pane does NOT
        render that -- it renders a bare ` task` row (verified on three panes, one carrying
        FOUR such rows, some historical, which is why a bare-row match is NOT a safe signal).
        So `pane_kids` was ALWAYS [].
      * `declared_children` reads the legacy /tmp/<prefix>-*.pid convention: 30 pid files
        against 21 live lanes, none of them for the affected lanes. So `declared` was ALWAYS [].
      * At the same moment SIX live session files carried an unmatched `task` toolCall.
    So `(declared or pane_kids)` was False on every lane running a `task` child and the
    suppression could not fire -- four false verdicts in one evening (Storage Architecture
    IDLE->WITHHELD, tortoise-sweep WEDGED, 2b Extractor STALL, 3 Onboarding STALL), two of them
    while the pane showed a live child.

    `child` comes from `pending_child()`, which reads THIS lane's own session file: EXACT
    attribution, which the cwd-based `child_file` walk structurally cannot give.

    The bound is ABANDON_S -- the SAME one `pending_child` applies. Past it the open call is a
    stale RECORD, and a stale record must not mask a real wedge. Absence never counts against a
    child: a missing `child_stale` (unreadable stat) is not evidence the child is dead.
    """
    bound = ABANDON_S if abandon_s is None else abandon_s
    live_child = bool(child) and not (child_stale is not None and child_stale > bound)
    return bool(declared or pane_kids or live_child) and verdict in ACTION_VERDICTS
                              # MEASURED 2026-09-27: this was 6*3600, so a child the
                              # harness had killed ~5.5 hours earlier was still returned
                              # as a live pending child and reported as `WAITING-CHILD
                              # child_age=106m`, which then made `turn-classify` SKIP
                              # that lane forever (it refuses to message a lane waiting
                              # on a child). One wrong constant disabled auto-continue.
# The `task` tool's own in-flight silence bound is stream_stall_ms, default 20 min.
# A pending child past this is either (a) legitimately in a long QUIET tool the
# dispatcher raised the bound for, or (b) the watchdog failed to fire — the #5195
# class. Either way it is the single most important thing to see.
OVERDUE_S = 25 * 60

# Lazy {pid: cwd} for every live `pi` process. Built once per run by
# _pi_pid_cwds() and reused by every lane's child_process_alive() probe, so the
# /usr/bin/python3 pgrep+lsof walk is paid once instead of once per lane.
_PI_MAP = None
_PI_PROCS = None
# NOTE: a child's own transcript is NOT inspectable. `task` children run `pi -p`
# and do not persist a session file anywhere under ~/.pi/agent/sessions, so the
# parent is blind to the child between dispatch and result. Only elapsed time and
# the child's on-disk effects are observable.


# ⛔ A FAILED READ IS RETRIED AT LEAST ONCE BEFORE IT IS BELIEVED (owner, 2026-10-12).
# The failure this guards is TRANSIENT BY NATURE: a control-socket call that times out under
# load (measured 13.4-15.1s per `cmux` call at load 130+, against a fixed 15s CLI deadline) is
# indistinguishable from a hang, and one immediate retry converts most of them into a real
# answer. Retrying costs a second; being wrong costs the fleet its monitor.
RETRY_ATTEMPTS = 2          # == one retry
RETRY_BACKOFF_S = 1.5


def sh_rc(cmd, timeout=60, attempts=RETRY_ATTEMPTS):
    """`(stdout, ok)`.

    `ok=False` means the CALL FAILED -- non-zero exit, timeout, or an unrunnable binary. An
    EMPTY stdout with `ok=True` is a SUCCESSFUL EMPTY READ, and the two must never render
    identically: collapsing them is how a degraded read became a confident verdict (see
    `_live_workspaces` and `resolve_session`, both of which treated "we could not look" as
    "there is nothing there").

    ⛔ AND WHY IT FAILED IS RECORDED, NOT FLATTENED INTO `ok=False`. `LAST_FAILURE` distinguishes
    a read that was REFUSED from one our own teardown KILLED. Measured 2026-10-12: all 23
    `DEGRADED -- the cmux fleet roster was unreadable` lines in the heartbeat log were immediately
    preceded by the tick being SIGTERM'd at its 390s bound, and NONE was a genuine read failure --
    cmux answered in 0.05-0.08s at load 69. The instrument was reporting a cause it had never
    established, blaming cmux for our own death, which is how a watchdog teaches its operator to
    ignore it. A signal-killed child is its own outcome.
    """
    global LAST_FAILURE
    LAST_FAILURE = None
    n = max(1, attempts)
    for i in range(n):
        try:
            p = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=timeout, env=CMUX)
            if p.returncode == 0:
                return p.stdout or "", True
            kind = "signal" if p.returncode is not None and p.returncode < 0 else "nonzero"
            LAST_FAILURE = dict(kind=kind, rc=p.returncode, cmd=cmd[0], attempt=i + 1)
        except subprocess.TimeoutExpired:
            LAST_FAILURE = dict(kind="timeout", rc=None, cmd=cmd[0], attempt=i + 1)
        except Exception as e:
            LAST_FAILURE = dict(kind="unrunnable", rc=None, cmd=cmd[0],
                                attempt=i + 1, error=type(e).__name__)
        if i + 1 < n:
            time.sleep(RETRY_BACKOFF_S * (i + 1))
    return "", False


def last_failure_was_teardown():
    """Whether the last failed read died by SIGNAL -- i.e. we were being torn down.

    A signal-killed child is not a refusal by the thing we were reading, and must not be reported
    as one (see `sh_rc`). Every other failure kind -- a non-zero exit, a timeout, an unrunnable
    binary -- IS a statement about the read and keeps the original wording.
    """
    return bool(LAST_FAILURE) and LAST_FAILURE.get("kind") == "signal"


def sh(cmd, timeout=60, attempts=RETRY_ATTEMPTS):
    return sh_rc(cmd, timeout, attempts)[0]


# ── DECISION-TREE STEP 2: CPU-TIME DELTA (the doc's STRONGEST signal) ─────────────────
# LANE-STATE-DECISION-TREE.md ranks this above every file probe: "A process consuming CPU time
# is *provably* executing, and a blocked API wait consumes none." Every input `classify()` had
# before this was a FILE probe (session mtime/size, child files, transcript) or a SCREEN scrape,
# and this file already documents the consequence of that blind spot in its own words:
#   "HANG read `CHILD-OVERDUE child=344m` while pid 64672 ran with CPU advancing 0:12.12 ->
#    0:14.62 over 45s, and ZERO session files existed under its worktree -- so every file-based
#    probe in this file was blind to it by construction."
#
# ⛔ WHY IT WAS DEFERRED, AND WHY THAT REASON IS NOW DISCHARGED. _pi_pid_cwds() explains that a
# cwd rule "CANNOT separate two sibling lanes that share one cwd: nine lanes rooted at the
# tortoise checkout each adopted pid 8167", so wiring it naively would trade a FALSE OVERDUE for
# a MISSED OVERDUE -- a masked real stall, "the worse error for a watchdog". That reasoning is
# correct and is PRESERVED here as a hard rule: see lane_cpu_busy() below, which returns None
# (no signal) whenever attribution is not EXACTLY ONE lane <-> EXACTLY ONE pid. It can only ever
# ADD a WORKING that is already proven, never suppress one.
#
# ⛔ THE INSTRUMENT MATTERS: `ps -o time` is cumulative CPU TIME, never `ps -o pcpu`, which is a
# LIFETIME AVERAGE and reads ~flat for a long-lived session that is working hard (the doc records
# only 3 of 73 processes moving by pcpu while many lanes were demonstrably working).
def _cpu_seconds(tok):
    """`MM:SS.ss` / `HH:MM:SS` / `D-HH:MM:SS` -> seconds. None if unparseable."""
    try:
        days = 0
        if "-" in tok:
            d, _, tok = tok.partition("-")
            days = int(d)
        secs = 0.0
        for b in tok.split(":"):
            secs = secs * 60 + float(b)
        return secs + days * 86400
    except Exception:
        return None


def _pi_cpu_map():
    """{pid: cumulative CPU seconds} for every live `pi`, in ONE ps call."""
    pids = (sh(["pgrep", "-x", "pi"]) or "").split()
    if not pids:
        return {}
    out = sh(["ps", "-o", "pid=,time=", "-p", ",".join(pids)])
    m = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) < 2:
            continue
        s = _cpu_seconds(f[-1])
        if s is not None:
            m[f[0]] = s
    return m


def _pi_cwd_map():
    """{pid: cwd} for ALL live pi in ONE `lsof` call.

    _pi_pid_cwds() does one lsof PER PROCESS (29 lanes -> 29 lsof runs, the slow path).
    This is the same data in a single call, cached for the run.
    """
    global _PI_PROCS
    if _PI_PROCS is not None:
        return _PI_PROCS
    m = {}
    pids = (sh(["pgrep", "-x", "pi"]) or "").split()
    if pids:
        out = sh(["lsof", "-a", "-d", "cwd", "-Fn", "-p", ",".join(pids)], timeout=45)
        cur = None
        for line in out.splitlines():
            if line.startswith("p"):
                cur = line[1:].strip()
            elif line.startswith("n") and cur:
                m[cur] = line[1:]
                cur = None
    _PI_PROCS = m
    return m


def lane_cpu_busy(label, session_file, dir_lanes, dir_pids, cpu0, cpu1):
    """True/False if this lane's pi process is provably consuming CPU; None if UNKNOWN.

    ⛔ STRICT ATTRIBUTION OR NO SIGNAL. The sessions directory name is a deterministic MANGLING
    of the cwd (`/Users/x/repo` -> `--Users-x-repo--`), so a pid's real cwd can be mapped to a
    lane's session dir EXACTLY -- no lossy demangling. But that only disambiguates when the group
    is unambiguous, so BOTH must hold: exactly ONE lane in that dir, and exactly ONE pi pid with
    that cwd. Two sibling lanes sharing one cwd (the measured 9-lane case) yield None, never a
    guess -- that is what keeps a masked stall impossible.
    """
    if not session_file or not cpu0 or not cpu1:
        return None
    try:
        d = os.path.basename(os.path.dirname(session_file))
    except Exception:
        return None
    if len(dir_lanes.get(d, [])) != 1:
        return None                     # two lanes share this cwd -> unattributable
    pids = dir_pids.get(d, [])
    if len(pids) != 1:
        return None                     # zero/many pids for this cwd -> unattributable
    p = pids[0]
    if p not in cpu0 or p not in cpu1:
        return None
    delta = cpu1[p] - cpu0[p]
    # A sub-0.1s twitch has the same signature from a parked child, a redraw and a timer wake,
    # so state the tolerance rather than letting the number mean nothing.
    return delta > 0.10


def lane_child_prefixes():
    """Registry column 4 (optional): prefix of the lane's detached-child pid files.

    A lane may launch children OUTSIDE its own root. Every signal in this file
    looks inside the root, so such a lane reads DONE-IDLE while it is working --
    and DONE-IDLE's instruction is "dispatch it", which duplicates live work.
    """
    out = {}
    try:
        lines = open(REG, errors="ignore").read().splitlines()
    except OSError:
        return out
    for line in lines:
        if not line or line.startswith("#") or "\t" not in line:
            continue
        parts = [p.strip() for p in line.split("\t")]
        if len(parts) > 3 and parts[3]:
            out[parts[0]] = parts[3]
    return out


def declared_children(label):
    """Live detached children the lane declared via /tmp/<prefix>-*.pid.

    A pid file OUTLIVES its process, so liveness is checked against the process
    and its command -- a stale file would otherwise invent a child that is gone.
    """
    prefix = lane_child_prefixes().get(label)
    if not prefix:
        return []
    found = []
    for path in sorted(glob.glob("/tmp/" + prefix + "-*.pid")):
        pid = sh(["cat", path]).strip()
        if not pid.isdigit():
            continue
        if sh(["ps", "-o", "comm=", "-p", pid]).strip() != "pi":
            continue
        cwd = None
        for ln in sh(["lsof", "-a", "-d", "cwd", "-p", pid, "-Fn"]).splitlines():
            if ln.startswith("n"):
                cwd = ln[1:]
                break
        found.append(dict(pid=int(pid), cwd=cwd, pidfile=os.path.basename(path)))
    return found


def _tsv_rows():
    """The hand-written file's rows: `(label, workspace, issue-label)`.

    ⛔ THESE ARE *METADATA*, NOT LANES (2026-10-12). The file is keyed by workspace uuid, and a
    workspace uuid DIES whenever the pane is recreated -- this fleet's normal recovery path
    (`respawn-pane` deletes and recreates it). So the file accumulates rows for workspaces that no
    longer exist. MEASURED 2026-10-12: the published roster carried 39 rows against 16 live cmux
    workspaces -- ~24 of them stale, which is why "the fleet" could not be read off it. The pane is
    the authority (the file's own header says so); this file supplies the two things a pane cannot
    express: the issue-label, and a title match for a lane whose uuid was recreated.
    """
    rows = []
    try:
        fh = open(REG, errors="ignore")
    except OSError:
        # ⛔ A MISSING/UNREADABLE REGISTRY IS AN ABSENCE, NOT AN EMPTY FLEET (2026-10-13). The
        # contract stated in this function is "never publish a roster it could not read" — but the
        # open() was unguarded, so an absent file raised out of the whole scan instead of
        # abstaining. A crash is not the safe direction here either: callers that catch and fall
        # back publish the TSV as the roster, which is exactly the failure this file was fixed to
        # stop. Returning nothing is what makes the EMPTY case visible instead of plausible: `main()`
        # refuses an empty roster (see its own guard), which names the unreadable read rather than
        # publishing an empty fleet. (This comment previously credited a `main()` guard that did not
        # exist — corrected 2026-10-13 when the guard was actually added.)
        return []
    with fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or "\t" not in line:
                continue
            parts = [p.strip() for p in line.split("\t")]
            label, ws = parts[0], parts[1]
            issue_label = parts[2] if len(parts) > 2 else ""
            rows.append((label, ws, issue_label))
    return rows


def registry():
    """`label<TAB>workspace<TAB>issue-label[<TAB>...]`

    The third column is the lane's GitHub issue label. It lives HERE, in the same
    row as the pane, because a lane's identity is its objective number and every
    consumer (the heartbeat, turn-end.py, a human) must read ONE mapping. A second
    copy of the lane->label map is exactly the two-names-for-one-lane defect the
    registry header describes. Trailing columns are ignored, and a missing third
    column yields "" rather than an error — a lane that owns no repo label
    (`HANG`, `A`) is a legitimate row.
    """
    tsv = _tsv_rows()
    live = _live_workspaces()
    by_uuid = {ws.upper(): il for _, ws, il in tsv}
    by_title = {label.strip().lower(): il for label, _, il in tsv}
    # ⛔ THE LIVE PANEL IS THE ROSTER; THE FILE IS ONLY METADATA (2026-10-12).
    # The roster used to be `TSV union live`, so a deleted lane kept being reported as a lane
    # forever -- 39 published rows against 16 live workspaces, i.e. two-thirds of the reported
    # "fleet" did not exist. Lanes open and close daily, so ANY hand-maintained roster is stale by
    # construction: "more of a general process that reads the lanes in cmux, than an outdated
    # list". We enumerate the panes that EXIST and use the file only to enrich them.
    #
    # The LABEL comes from the live pane title, never from the file: the naming scheme makes those
    # the same string, and taking the live one means a renamed lane is reported under its real name
    # instead of whatever it was called when someone last hand-edited a file. The file is consulted
    # for the issue-label by workspace uuid, else by title -- which is what preserves a lane's issue
    # label across the uuid churn that recreating a pane causes.
    rows = []
    for wsid, x in live:
        title = _live_label(wsid, x)
        il = by_uuid.get(wsid.upper()) or by_title.get(title.strip().lower()) or ""
        rows.append((title, wsid, il))
    if LIVE_READABLE is False:
        # ⛔ A DEGRADED READ MUST BE LOUD *AND* MUST NOT PRETEND TO BE A FLEET. We cannot enumerate
        # the panes, so we fall back to the file's rows -- but the caller stamps every row
        # `degraded` and `lane-actions.py` REFUSES such a snapshot, because it covers the file only
        # and every live-only lane is INVISIBLE in it.
        # stderr, so stdout stays a parseable fleet read for callers that inspect LIVE_READABLE.
        # ⛔ THE REASON IS REPORTED, NOT INVENTED. A read our own teardown killed is NOT an
        # unreadable roster -- see `sh_rc`. Getting this wrong is how 23 consecutive log lines
        # blamed cmux for a SIGTERM to the tick, and how an operator learns to ignore the alarm.
        if last_failure_was_teardown():
            sys.stderr.write(
                "lane-status: DEGRADED -- the cmux fleet read was KILLED BY A SIGNAL "
                f"(rc={LAST_FAILURE.get('rc')}), i.e. this process was being torn down (most likely "
                "the heartbeat tick hitting its stall bound). This is NOT a claim that cmux is "
                "down. The scan below covers the hand-written TSV only, so every live-only lane is "
                "INVISIBLE in it -- do NOT publish it as a fleet read.\n")
        else:
            sys.stderr.write(
                "lane-status: DEGRADED -- the cmux fleet roster was unreadable after "
                f"{RETRY_ATTEMPTS} attempts ({LAST_FAILURE or 'no failure recorded'}); this scan "
                "covers the hand-written TSV only, so every live-only lane is INVISIBLE to it. "
                "Do NOT publish this as a fleet read.\n")
        return tsv
    return rows


# ── THE ROSTER IS NOT THE FLEET ────────────────────────────────────────────────
# registry() read lane-registry.tsv, a HAND-WRITTEN file. Measured 2026-09-28 23:05:
# 14 rows against 27 live cmux workspaces — 13 lanes the monitor could not see,
# including EVERY objective lane dispatched that evening (#4844, #2875, #3653, #6135)
# and both research streams. Because the heartbeat and turn-classify both iterate
# this list, an unlisted lane is never classified, never alerted and never nudged:
# it sits idle while the fleet reports itself healthy. The registry's own header
# says the authority is the PANE, so cmux is the source and the TSV only supplies
# the label<->issue-label mapping that cmux cannot know.
# FAILS OPEN: cmux unreachable -> the TSV rows alone, exactly as before.
# The orchestrator's own cmux workspace -- excluded from the lane registry; it is the
# reader, not a lane. ORCH_WS from the environment wins (the heartbeat exports it).
ORCH_WS = os.environ.get("ORCH_WS", "C2C97E96-0CBC-4DFE-BC91-FEF44F09B5BD")

_LIVE_CACHE = []

# Did the FLEET ROSTER actually read? `None` = not attempted; `True`/`False` = the answer.
# ⛔ THIS EXISTS BECAUSE AN EMPTY LIST IS NOT AN ANSWER. `_live_workspaces()` swallowed every
# failure into `[]`, and `registry()` unions the hand-written TSV with that list -- so an
# unreachable cmux silently degenerated the fleet back to the TSV. MEASURED 2026-10-12: the
# published snapshot carried 26 workspaces, ALL of them TSV and ZERO of the 13 live-only ones
# (`CMUX cloud`, `decisions`, the reader's own viewer) -- while 4 lanes were stalled. The comment
# under `registry()` records the SAME failure on 2026-09-28 ("13 lanes the monitor could not
# see"); a fallback indistinguishable from a healthy read is how it comes back, silently.
LIVE_READABLE = None
LAST_FAILURE = None


def _live_workspaces():
    global LIVE_READABLE
    if _LIVE_CACHE:
        return _LIVE_CACHE[0]
    rows = []
    out, ok = sh_rc(["cmux", "list-workspaces", "--json"], timeout=45)
    try:
        if not ok:
            raise ValueError("cmux fleet roster unreadable")
        data = json.loads(out)
        for x in (data if isinstance(data, list) else data.get("workspaces", [])):
            wsid = str(x.get("id") or "").strip()
            # ── THE ORCHESTRATOR IS NOT A LANE ────────────────────────────────
            # Its own workspace carries a lane-shaped title (measured 2026-09-29:
            # ORCH_WS was titled "Packs + Extractor"), so without this guard the
            # registry reports a phantom 28th lane, `turn-classify` will NUDGE THE
            # ORCHESTRATOR to go do lane work, and every content scan self-matches --
            # the orchestrator's transcript mentions every issue number it discusses,
            # which is exactly why a holder scan returned the orchestrator itself as
            # the top candidate for #6142. Excluded by id, never by title (titles are
            # user-facing and can be renamed at any time).
            if wsid.upper() == ORCH_WS.upper():
                continue
            if wsid:
                rows.append((wsid, x))
        # ⛔ AN EMPTY LIST IS NOT AN ANSWER -- THE SAME RULE THE REST OF THIS FILE RUNS ON.
        # `sh_rc` returning ok only means the COMMAND succeeded. A renamed key after a cmux version
        # bump, `{}`, or `{"error": ...}` on a zero exit all leave `ok=True` and this list EMPTY,
        # which published `LIVE_READABLE=True` with a zero-row roster: registry() returns [], the
        # snapshot is [], and the freshness test (`-s "$SNAP"`) refuses to launch the fallback scan,
        # so the fleet goes DARK while every read-quality flag says healthy. MEASURED by an
        # adversarial review 2026-10-12: `{"error":"no such subcommand"}` with rc=0 produced
        # exactly that. The owner always has workspaces, and reporting an unreadable fleet is the
        # safe direction.
        if not rows:
            raise ValueError("cmux roster parsed but yielded no workspaces")
    except Exception:
        # ⛔ NOT A NEUTRAL FALLBACK. This is the shrink that hides 13 lanes; it is recorded in
        # LIVE_READABLE so the caller can REFUSE rather than publish a confident partial fleet.
        rows, ok = [], False
    LIVE_READABLE = ok
    _LIVE_CACHE.append(rows)
    return rows


def _submitted_epoch(ws):
    """The lane's last INBOUND turn, from the cmux record, PLUS whether cmux was readable.

    Returns `(epoch, readable)`, and the SECOND element is the point -- "we could not read cmux"
    and "cmux read fine but this lane has no inbound record" are DIFFERENT FACTS and must not
    render identically (an absent signal is not a failed read, and a failed read must never be
    reported as an empty success).

      (epoch, True)  -> the workspace's last inbound turn
      (None,  True)  -> cmux READ OK; this lane simply has no inbound record (e.g. it is not a
                        live cmux workspace at all, only a row from the session-file union)
      (None,  False) -> cmux itself could not be read -- UNREAD, and nothing follows from it

    Reads the SAME cached `_live_workspaces()` payload the roster union already fetches, so this
    costs no extra `cmux` call. Never 0: an unread timestamp must not read as "submitted in
    1970" (which would discount everything) nor as a confident "no inbound".
    """
    live = _live_workspaces()
    if not live:
        return None, False
    want = (ws or "").upper()
    for wsid, x in live:
        if wsid.upper() == want:
            return ts_epoch(x.get("latest_submitted_at")), True
    return None, True


# Long enough to tell "WORK ORDER: fix the python-ci-gate..." from "quick question about...", short
# enough that one lane stays one line. The table is a triage surface, not a transcript.
INBOUND_MSG_MAX = 72


def _inbound_message(ws):
    """The last turn SUBMITTED TO this lane -- INBOUND -- sanitised to one short line, or None.

    ⛔ INBOUND, and the distinction is the whole correction: this is what someone SENT the lane, not
    what the lane PRODUCED. It is not evidence of liveness and must never be read as such; its job
    is to make a `RECENT-INBOUND` suppression auditable, because that verdict is the same whether
    the lane was just handed work (leave it alone) or was asked a question and went quiet (act on
    it), and only the text separates those.

    Reads the SAME cached `_live_workspaces()` payload as `_submitted_epoch`, so it costs no extra
    `cmux` call. Returns `None` -- never `""` -- when there is no record, so an absent message
    cannot render as a present-but-empty one.
    """
    live = _live_workspaces()
    if not live:
        return None
    want = (ws or "").upper()
    for wsid, x in live:
        if wsid.upper() != want:
            continue
        m = x.get("latest_submitted_message")
        if not isinstance(m, str) or not m.strip():
            return None
        one = " ".join(m.split())
        return one if len(one) <= INBOUND_MSG_MAX else one[:INBOUND_MSG_MAX] + "..."
    return None


def _live_label(wsid, x):
    t = (x.get("custom_title") or "").strip()
    if t:
        return t
    cwd = (x.get("current_directory") or "").rstrip("/")
    base = os.path.basename(cwd) or "workspace"
    return f"{base} ({wsid[:8]})"


def _recorded_session(ws):
    """The lane->session mapping the recovery tooling writes (lane-sessions.json)."""
    try:
        p = os.path.join(os.path.dirname(REG), "lane-sessions.json")
        for L in json.load(open(p)):
            if L.get("uuid") == ws:
                return L.get("session")
    except Exception:
        pass
    return None


def resolve_session(ws):
    """The lane's session id, for a caller that wants nothing else (lane-guard.py)."""
    return resolve_session_ex(ws)[0]


def resolve_session_ex(ws):
    """`(session_id, verified)` — resolve from the PANE, never a pinned id: pins die on respawn.

    ⛔ `verified` IS NOT DECORATION, AND ITS ABSENCE IS WHY THIS WAS WRONG TWICE. A resolved id
    is only as good as the read that produced it, and there are paths that cannot check it.
    MEASURED 2026-10-12, all from ONE unreadable cmux socket: `Storage Archictecture` bound to a
    session last written 64h18m earlier and `5&9 MCP and SDK surface` to one 12h30m earlier --
    both published as `DONE-IDLE`, while the panes were demonstrably on other sessions. The
    freshness check below existed and could not fire, because it sits AFTER the returns.
    `verified=False` means "this id could not be confirmed as the one being written", so the
    verdict built on it must ABSTAIN rather than assert idleness.

    BUT (2026-09-27) the pane's cmux resume record is not authoritative after a
    MANUAL relaunch. Relaunching a lane by typing `pi --session <id>` into its
    pane (the documented recovery path — respawn-pane DELETES workspaces) leaves
    cmux with either NO record (read as UNBOUND) or the PRE-crash id. The stale
    id made a working lane read DONE-IDLE for hours: the file glob found the old
    session, saw no writes, and called the lane idle.

    So neither source is trusted blindly: both candidates are resolved to a real
    file and the one actually being WRITTEN wins. When only one resolves, it is
    used. This self-corrects in either direction and cannot pin a dead id while a
    live one exists.
    """
    out = sh(["cmux", "surface", "resume", "show", "--workspace", ws])
    m = re.search(r"--session' '([0-9a-f-]{36})", out) or \
        re.search(r"--session[= ]'?([0-9a-f-]{36})", out)
    pane = m.group(1) if m else None
    rec = _recorded_session(ws)

    expect_live = True
    if not pane:
        # No parseable id from the pane. The RECORDED id is a recovery hint, not a liveness
        # proof, so it is taken UNVERIFIED -- the check at the end decides what it is worth.
        # Returning it unchecked here is the defect in the docstring, surviving on the one path
        # where there is nothing for it to disagree with.
        chosen, had_pane = rec, False
        # ⛔ A DEAD LANE IS NOT AN UNVERIFIED ONE. This flag catches a LIVE lane mis-bound to a
        # session nobody is writing -- the case that renders `DONE-IDLE` and invites a duplicate
        # dispatch. The TSV half of the registry is largely stale (MEASURED 2026-10-12: 24 of 39
        # rows are not live cmux workspaces, and `surface resume show` on a dead one prints to
        # stderr, writes 0 bytes to stdout and EXITS 0 -- so that empty read is indistinguishable
        # from a real one and the recorded id is simply history). Firing on those would flood
        # REPORT ONLY with lanes that are merely gone and bury the real signal, and a dead
        # workspace cannot be mis-bound in a way that costs anything.
        try:
            # ⛔ A ROSTER WE COULD NOT READ IS "UNKNOWN", NEVER "NOT LIVE". When cmux is
            # unreadable `_live_workspaces()` returns EMPTY, so this membership test answered False
            # for every row and the caller concluded `not expect_live` -> `verified=True` on exactly
            # the unreadable-cmux case the flag was written for. The impact was masked only because
            # lane-actions refuses `degraded` snapshots -- i.e. the guard's correctness depended on a
            # DIFFERENT guard, and any change to the degradation policy would silently reopen it.
            if LIVE_READABLE is False:
                expect_live = True
            else:
                expect_live = (ws or "").upper() in {w.upper() for w, _x in _live_workspaces()}
        except Exception:
            expect_live = True      # cannot tell -> never silently clear the flag
    elif not rec or rec == pane:
        chosen, had_pane = pane, True
    else:
        pf, rf = session_file(pane), session_file(rec)
        if pf and rf:
            chosen = rec if os.path.getmtime(rf) > os.path.getmtime(pf) else pane
        elif rf and not pf:
            chosen = rec
        else:
            chosen = pane
        had_pane = True
    if not chosen:
        # `verified=None` -- NOT False. There is no id here, so "could not confirm it" is not a
        # statement about anything; the row's abstention is `sid is None`, which the consumer
        # already reads first. A flag that fires where it does not apply is how a real one gets
        # ignored.
        return None, None

    # LAST RESORT (2026-09-27, measured): everything above still assumes one of the
    # two ids is the LIVE one. After a manual relaunch a lane can be writing to a
    # THIRD session file that neither cmux nor lane-sessions.json knows, and then
    # every source is stale and a working lane reads DONE-IDLE. MEASURED at 04:15:
    # the classifier said active=0 while 12 of 14 lanes were writing. So when the
    # chosen file has gone quiet, look for a newer file in the same directory whose
    # FIRST USER MESSAGE names this lane — the fleet's own identity signal, and the
    # technique match-lanes.py uses to disambiguate a shared sessions directory.
    cf = session_file(chosen)
    if cf and (time.time() - os.path.getmtime(cf)) > 1800:
        label = next((l for l, w, _ in registry() if w == ws), "")
        alt = _content_session(label, cf)
        if alt:
            return os.path.basename(alt)[:-len(".jsonl")].split("_")[-1], True
    if had_pane or not expect_live:
        # ⛔ A QUIET SESSION IS NOT AN UNCONFIRMED ONE. The PANE is authoritative about which
        # session it is running, and a lane waiting on a long child writes NOTHING for as long as
        # the child runs -- that is the shape this whole file exists to classify correctly. So
        # "the file has not been written for an hour" must NOT be read as "this is not the live
        # session"; only the ABSENCE of any id (cmux unread, and nothing corroborates the
        # recorded one) leaves the id unverified.
        return chosen, True
    # No id came from the pane: the recorded id is a recovery hint, and it is only VERIFIED if
    # something corroborates it -- a write recent enough to be the live session. This is the path
    # that bound two lanes to sessions last written 64h18m and 12h30m earlier.
    return chosen, bool(cf) and (time.time() - os.path.getmtime(cf)) <= SESSION_VERIFY_S


def _first_user_message(path):
    """The first user turn's text — how this fleet identifies a lane."""
    try:
        with open(path, errors="ignore") as fh:
            for line in fh:
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if not isinstance(o, dict):
                    continue
                if o.get("type") != "user" and o.get("role") != "user":
                    continue
                c = o.get("content")
                if c is None and isinstance(o.get("message"), dict):
                    c = o["message"].get("content")
                if isinstance(c, list):
                    c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
                if c:
                    return str(c)
    except Exception:
        pass
    return ""


def _content_session(label, stale_file):
    """Newest session file in the lane's dir whose first user message names the lane.

    Bounded to the last 6h of files and only consulted when the primary resolution
    is already known stale, so a quiet fleet costs nothing.
    """
    d = os.path.dirname(stale_file or "")
    if not (label and os.path.isdir(d)):
        return None
    stop = {"and", "the", "of", "for", "core", "keys", "lane"}
    toks = [t for t in re.split(r"[^a-z0-9]+", label.lower()) if len(t) > 2 and t not in stop]
    if not toks:
        return None
    need = max(1, (len(toks) + 1) // 2)
    try:
        base = os.path.getmtime(stale_file)
    except OSError:
        base = 0
    cutoff = time.time() - 6 * 3600
    best, bmt = None, 0
    for f in glob.glob(os.path.join(d, "*.jsonl")):
        try:
            mt = os.path.getmtime(f)
        except OSError:
            continue
        if mt <= base or mt < cutoff:
            continue
        txt = _first_user_message(f).lower()
        if txt and sum(1 for t in toks if t in txt) >= need and mt > bmt:
            best, bmt = f, mt
    return best


def session_file(sid):
    if not sid:
        return None
    hits = glob.glob(f"{SD}/*/*{sid}*.jsonl")
    return max(hits, key=os.path.getmtime) if hits else None


def mangled(cwd):
    """cwd -> session directory name. `/a/b.c` -> `--a-b-c--`

    The wrapper supplies the two dashes and the ROOT slash is consumed by it, so
    the leading `/` must be stripped first — otherwise `/a` becomes `---a--` and
    every lookup misses.
    """
    return "--" + re.sub(r"[/.]", "-", cwd.strip("/")) + "--"


def records(path, limit=None):
    out = []
    try:
        with open(path, errors="ignore") as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    out.append(json.loads(line))
                except Exception:
                    continue
                if limit and len(out) >= limit:
                    break
    except Exception:
        pass
    return out


def tail(path, want=8):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            back = min(size, 300_000)
            f.seek(size - back)
            chunk = f.read().decode("utf-8", "ignore")
        out = []
        for line in reversed([l for l in chunk.split("\n") if l.strip()]):
            try:
                out.append(json.loads(line))
            except Exception:
                continue
            if len(out) >= want:
                break
        return list(reversed(out))
    except Exception:
        return []


def describe(rec):
    m = rec.get("message") or {}
    role = m.get("role") or rec.get("type") or "?"
    content = m.get("content")
    if isinstance(content, str):
        return role, content[:200].replace("\n", " ")
    if isinstance(content, list):
        texts, tools = [], []
        for c in content:
            if not isinstance(c, dict):
                continue
            t = c.get("type")
            if t == "text" and c.get("text", "").strip():
                texts.append(c["text"].strip())
            elif t in ("toolCall", "tool_use"):
                args = c.get("arguments") or c.get("input") or {}
                hint = args.get("task") or args.get("command") or args.get("file_path") or ""
                tools.append(f"{c.get('name','?')}({str(hint)[:40]})")
        if tools:
            return "tool", "tools: " + ",".join(tools[:4])
        if texts:
            return role, texts[0][:200].replace("\n", " ")
    return role, ""


def ts_epoch(ts):
    """ISO timestamp -> epoch seconds (UTC-aware)."""
    if not ts:
        return None
    try:
        import calendar
        return calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
    except Exception:
        return None


def _pi_pid_cwds():
    """{pid: cwd} for every live `pi` process, built ONCE per run.

    NOTE 2026-09-27: this and child_process_alive() are DELIBERATELY UNUSED.
    The parentage technique below is correct and was measured working (HANG's
    child 64672 -> parent pi 33286; lane A's own session 1744 -> parent zsh
    1696), but a cwd/parentage rule CANNOT separate two sibling lanes that share
    one cwd: nine lanes rooted at the tortoise checkout each adopted pid 8167.
    Since the only available disambiguator is the lane's own issue list, which
    this function is not given, wiring it would trade a FALSE OVERDUE (a weak
    alarm, already documented) for a MISSED OVERDUE (a masked real stall) -- the
    worse error for a watchdog. Kept as the designed fix, not shipped.
    """
    global _PI_MAP
    if _PI_MAP is not None:
        return _PI_MAP
    m = {}
    try:
        pids = sh(["pgrep", "-x", "pi"]).split()
    except Exception:
        pids = []
    for p in pids:
        try:
            out = sh(["lsof", "-p", p, "-a", "-d", "cwd", "-Fn"])
        except Exception:
            continue
        for line in out.splitlines():
            if line.startswith("n"):
                m[p] = line[1:]
                break
    _PI_MAP = m
    return m


def child_process_alive(cwd):
    """UNUSED -- see _pi_pid_cwds() for why this was designed but not wired.

    The technique is sound and was measured (2026-09-27): a `task`/`subagent`
    child's parent IS a pi process (64672 -> 33286, at agent-infra), while a
    lane's OWN session was started from a shell (1744 -> 1696, zsh). The
    blocking defect is cwd-collision between sibling lanes, not the rule.

    What it would have fixed: HANG read `CHILD-OVERDUE child=344m` while pid
    64672 ran with CPU advancing 0:12.12 -> 0:14.62 over 45s, and ZERO session
    files existed under its worktree -- so every file-based probe in this file
    was blind to it by construction.

    To wire this safely it must be given the lane's issue numbers, so the
    child's cwd can be matched to THIS lane (e.g. `l59-3656` for c5-9) instead
    of to the shared repo root. That is a larger change than could be validated
    here.
    """
    root = os.path.abspath(cwd)
    for pid, pth in _pi_pid_cwds().items():
        try:
            p = os.path.abspath(pth)
        except Exception:
            continue
        if p.startswith(root + os.sep):
            return int(pid) if pid.isdigit() else True
    return None


def child_activity(cwd, minutes=20):
    """Newest write under the child's cwd in the last N minutes -> age in seconds.

    The only observable effect a `task` child has on the world, since its
    transcript is not persisted. Bounded depth and .git excluded for speed.
    """
    if not cwd or not os.path.isdir(cwd):
        return None
    newest = None
    now = time.time()
    try:
        for root, dirs, files in os.walk(cwd):
            if root.count(os.sep) - cwd.count(os.sep) > 3:
                dirs[:] = []
                continue
            dirs[:] = [d for d in dirs if d not in (".git", "__pycache__", "node_modules", ".venv")]
            for fn in files:
                try:
                    mt = os.path.getmtime(os.path.join(root, fn))
                except Exception:
                    continue
                if mt > now - minutes * 60 and (newest is None or mt > newest):
                    newest = mt
            if newest and time.time() - newest < 60:
                break
    except Exception:
        return None
    return int(time.time() - newest) if newest else None


def last_tool_call(path):
    """(timestamp, declared_timeout_s, name) for the newest tool call, if it is the
    last thing and has no result yet — i.e. it is still in flight.
    """
    call = None
    result_ids = set()
    for r in records(path):
        m = r.get("message") or {}
        if m.get("role") == "assistant":
            for c in (m.get("content") or []):
                if isinstance(c, dict) and c.get("type") in ("toolCall", "tool_use"):
                    args = c.get("arguments") or c.get("input") or {}
                    call = (r.get("timestamp"), args, c.get("name"), c.get("id"))
        elif m.get("role") == "toolResult":
            result_ids.add(m.get("toolCallId"))
    if not call or call[3] in result_ids:
        return None
    ts, args, name, _ = call
    tmo = args.get("timeout") or args.get("timeout_seconds") or args.get("timeout_s")
    if tmo is None:
        cmd = str(args.get("command") or "")
        mt = re.search(r"timeout\s+(\d+)\s*s?\b", cmd)
        if mt:
            tmo = int(mt.group(1))
    try:
        tmo = int(float(tmo)) if tmo is not None else None
    except Exception:
        tmo = None
    return dict(ts=ts, name=name, timeout=tmo)


def in_flight_tool(f):
    """The PARENT's newest in-flight tool call as {name, timeout, age}, or None.

    ⛔ IT TAKES NO CHILD ARGUMENT, AND THAT IS THE POINT. The guard this feeds was once written
    `if f and not (child and child_has_evidence(...))`, so a record about a CHILD could suppress a
    fact about the PARENT -- and it did. MEASURED 2026-10-12, `Drain (PR queue support)`: its pi held
    a live `bash -> sleep 52` poll loop (0 CPU, no established connection) while an abandoned `task`
    record from 3.9 days earlier sat in its session (`child_stale` 334455s). `ti` was left None, the
    long-tool guard could not fire, and the lane read CHILD-STUCK where the PRE-CHANGE instrument
    read LONG-TOOL. A function that cannot see a child cannot be made to depend on one, so the
    suppression is impossible by construction rather than merely commented against. `child_has_evidence`
    still decides the child branch in `classify()` -- it was simply never the right question here.
    """
    if not f:
        return None
    tc = last_tool_call(f)
    if not tc:
        return None
    e = ts_epoch(tc["ts"])
    return dict(name=tc["name"], timeout=tc["timeout"],
                age=int(time.time() - e) if e else None)


def parent_cwd(path):
    """The cwd a session was started in — first record carries it."""
    try:
        o = json.loads(open(path, errors="ignore").readline())
        return o.get("cwd")
    except Exception:
        return None


def pending_children(parent_file):
    """ALL unmatched child calls, newest first.

    ⛔ ALL OF THEM, NOT JUST THE NEWEST (2026-10-12). A lane dispatches in PARALLEL: `5&9 MCP and
    SDK surface` held FIVE unmatched calls from one `task(),task(),task(),task()` round, and
    judging it by `open_calls[-1]` picked the single quietest child and read `CHILD-STUCK` while
    two siblings had transcripts written 8m and 12m earlier and the pane was running
    `admin-merge.sh`. `lane-actions.py` routes CHILD-STUCK to "unblock it", so that verdict is an
    action aimed at a lane that is working. This is the failure this file already records -- "5&9
    read CHILD-STUCK off a 27m-old pending child while its pane showed TWO live children" -- and
    it returned because the fix looked at ONE child. A lane is waiting if ANY child is live.

    ⛔ AND AN OLD RECORD IS KEPT, NEVER ERASED: `abandoned` is reported so `classify()` can
    decide. Erasing it asserted the child was DEAD, on a premise that is false (measured: three
    task children alive and running pytest at 2h26m, a child polling CI at 1h30m). What ABANDON_S
    legitimately answers is whether a record may SUPPRESS a verdict (`child_suppresses`), never
    whether the child exists.
    """
    calls = {}
    results = set()
    for r in records(parent_file):
        m = r.get("message") or {}
        if m.get("role") == "assistant":
            for c in (m.get("content") or []):
                if isinstance(c, dict) and c.get("type") in ("toolCall", "tool_use") \
                        and c.get("name") in TOOL_NAMES:
                    args = c.get("arguments") or c.get("input") or {}
                    calls[c.get("id")] = (r.get("timestamp"), args)
        elif m.get("role") == "toolResult" and m.get("toolName") in TOOL_NAMES:
            results.add(m.get("toolCallId"))
    out = []
    for cid, (ts, args) in reversed([(c, v) for c, v in calls.items() if c not in results]):
        age = None
        if ts:
            e = ts_epoch(ts)
            if e:
                age = int(time.time() - e)
        # `subagent` passes `task`; the `task` tool passes `prompt`. Both carry `cwd`
        # only sometimes, so fall back to the parent's own cwd.
        hint = args.get("task") or args.get("prompt") or ""
        out.append(dict(call_id=cid, ts=ts, age=age,
                        abandoned=age is not None and age > ABANDON_S,
                        cwd=args.get("cwd") or parent_cwd(parent_file),
                        task=hint[:120],
                        agent=args.get("agent") or "?"))
    return out


def most_live_child(kid_calls, exclude=None):
    """The child of a parallel round that carries the most liveness evidence.

    ⛔ EVIDENCE, NOT ORDER -- see `pending_children`. The freshest transcript wins; a child with no
    transcript at all loses to one that has any.
    """
    best, best_file, best_age = None, None, None
    for k in kid_calls:
        c = find_child_session(k["cwd"], ts_epoch(k["ts"]), exclude=exclude) \
            if k.get("cwd") else None
        a = int(time.time() - os.path.getmtime(c)) if c else None
        if best is None or (a is not None and (best_age is None or a < best_age)):
            best, best_file, best_age = k, c, a
        # ⛔ STOP ON THE FIRST CLEARLY-LIVE CHILD. `find_child_session` walks the task-session dir,
        # and `main()` hands this every open dispatch -- so a five-call parallel round (the exact
        # case this change targets) paid five walks on the tick's documented 90-300s critical path.
        # A child measured inside the long-tool window has already decided the question.
        if a is not None and a < 900:
            break
    return best, best_file


def pending_child(parent_file):
    """The NEWEST unmatched child call, for a caller that wants exactly one.

    `main()` does NOT use this: it takes `pending_children()` and picks on EVIDENCE, because the
    newest is not the most live and judging a parallel round by one arbitrary member is the defect
    `pending_children` documents.
    """
    kids = pending_children(parent_file)
    return kids[0] if kids else None


def last_child_verdict(parent_file):
    """The verdict text of the most recent COMPLETED child, if it failed."""
    last = None
    for r in records(parent_file):
        m = r.get("message") or {}
        if m.get("role") == "toolResult" and m.get("toolName") in TOOL_NAMES:
            txt = " ".join(x.get("text", "") for x in (m.get("content") or [])
                           if isinstance(x, dict))
            for v in RESULT_VERDICTS:
                if txt.startswith(v):
                    last = (v, r.get("timestamp"))
    return last


def task_child_candidates(after_ts):
    """Child transcript dirs that could belong to a dispatch made at `after_ts`.

    Bounded by the dir's own mtime: a dispatch from 80 minutes ago cannot have
    produced a child dir last written before it. That prunes 14,900 dirs to a
    handful and keeps this cheap enough to run every tick.
    """
    out = []
    try:
        with os.scandir(TASK_SD) as it:
            for e in it:
                try:
                    if not e.is_dir(follow_symlinks=False):
                        continue
                    mt = e.stat(follow_symlinks=False).st_mtime
                except OSError:
                    continue
                if after_ts is not None and mt < after_ts - 120:
                    continue
                out.append((mt, e.path))
    except OSError:
        return []
    out.sort(reverse=True)
    return [p for _, p in out]


def _same_dir(a, b):
    """Compare two cwds, resolving symlinks.

    `/tmp/x` and `/private/tmp/x` are the SAME directory on macOS and both spellings
    occur (a brief says /tmp/…, the child records /private/tmp/…). Without realpath
    the match silently never fires -- the same class of always-None as the bug this
    function fixes.
    """
    if not a or not b:
        return False
    ra, rb = os.path.realpath(a), os.path.realpath(b)
    return ra == rb or ra.startswith(rb + os.sep) or rb.startswith(ra + os.sep)


def find_child_session(cwd, after_ts, exclude=None):
    """Locate a task child's transcript.

    ⛔ Two trees, and the child is only ever in the second one:
      · `SD`            -- parent sessions, keyed by mangled cwd (the OLD search)
      · `TASK_SD`       -- a `task` child's OWN transcript dir, keyed by child uuid

    Searching `SD` alone meant `child_file` was ALWAYS None, so `child_stale` and
    `child_grew` never carried a value: every lane blocked on a child read
    CHILD-OVERDUE with no evidence whether that child was parked or working.
    Measured 2026-09-25: 14,934 dirs in TASK_SD, 0 mentions of it in this file.

    TASK_SD is searched first (that is where children actually are); the parent
    tree is retained as a fallback for a child that genuinely shares its parent's
    cwd. Candidates must post-date the dispatch.
    """
    if not cwd:
        return None

    for d in task_child_candidates(after_ts):
        for f in sorted(glob.glob(os.path.join(d, "*.jsonl")),
                        key=os.path.getmtime, reverse=True):
            try:
                if after_ts is not None and os.path.getmtime(f) < after_ts - 120:
                    continue
                o = json.loads(open(f, errors="ignore").readline())
            except Exception:
                continue
            if _same_dir(o.get("cwd"), cwd):
                return f

    d = os.path.join(SD, mangled(cwd))
    if not os.path.isdir(d):
        return None
    excl = os.path.abspath(exclude) if exclude else None
    best, fallback = None, None
    for f in glob.glob(os.path.join(d, "*.jsonl")):
        if excl and os.path.abspath(f) == excl:
            continue
        mt = os.path.getmtime(f)
        if fallback is None or mt > os.path.getmtime(fallback):
            fallback = f
        if after_ts is not None and mt < after_ts - 120:
            continue
        if best is None or mt > os.path.getmtime(best):
            best = f
    best = best or (fallback if after_ts is None else None)
    if best is None:
        return None
    try:
        o = json.loads(open(best, errors="ignore").readline())
        if o.get("cwd") and os.path.abspath(o["cwd"]) != os.path.abspath(cwd):
            return None
    except Exception:
        pass
    return best


def read_screen(ws, lines=80):
    """The pane's text, in ONE cmux call -- shared by the spinner test and the
    child-line parse, so adding the child parse costs no extra round trip."""
    return sh(["cmux", "read-screen", "--workspace", ws, "--lines", str(lines)])


def ui_working(ws):
    return "Working" in read_screen(ws, 12)


# pi prints one of these per LIVE child: child id, transcript dir, parent session.
CHILD_LINE_RE = re.compile(r"\[task\]\s+child\s+session\s+(\S+?)\s*\u2192\s*(\S+)")


def parse_child_lines(screen):
    """Live `task` children read straight off the pane. Authoritative, and the
    only child source that sees children launched OUTSIDE the lane's own root --
    cwd matching structurally cannot, and that is what made a lane with two live
    children read DONE-IDLE (measured 2026-09-26, three lanes / five children).

    Freshness comes from the newest file INSIDE the child's transcript dir, never
    from the dir's own mtime: measured the same day, all five live children had a
    dir mtime of 11m (the dir is created once) while their transcripts were 0-11m.

    The pane scrolls, so absence means UNKNOWN -- never "no child".
    """
    kids = []
    for m in CHILD_LINE_RE.finditer(screen or ""):
        cid, path = m.group(1), m.group(2).rstrip("),")
        if not os.path.isdir(path):
            continue                      # the pane can outlive the child's dir
        try:
            newest = max(os.path.getmtime(os.path.join(path, x))
                         for x in os.listdir(path))
        except Exception:
            continue
        kids.append(dict(id=cid, path=path, age=int(time.time() - newest)))
    return kids


def child_has_evidence(child, child_stale, child_grew, child_activity_age):
    """Whether we hold evidence ABOUT the child, as opposed to merely a record that one started.

    An unmatched dispatch proves a child was STARTED -- never, by itself, anything about what it is
    doing. When the child left no trace at all (no transcript, no on-disk effect, no sampled
    growth), the parent's own state is the better witness and must get to answer. ONE definition,
    used by `classify()` AND by main's in-flight-tool guard: two inline copies is how the two
    drifted, and the drift is what let `Storage Archictecture` read CHILD-STUCK mid-`bash` on
    2026-10-12 (see the note in `classify`).

    ⛔ BUT `child_stale is not None` IS THE WRONG QUESTION FOR THE LONG-TOOL GUARD, and gating that
    guard on this helper is what kept a lane in a LIVE poll loop reading CHILD-STUCK. `child_stale`
    is known whenever a transcript exists, so this returns True for a 72195s-stale record in the
    very `Storage Archictecture` case cited above and for a 334455s (3.9-day) one on `Drain` -- the
    guard below was therefore skipped exactly when it was needed, and `Drain`'s live
    `bash -> sleep 52` (0 CPU, no connection) read CHILD-STUCK where the pre-change instrument
    correctly read LONG-TOOL. Whether we hold a record ABOUT a child says nothing about whether the
    PARENT has a tool in flight; those are two different facts and each guard must ask its own.
    Measured after the fix, `Drain`: LONG-TOOL, matching the pre-change instrument.
    """
    return bool(child) and (
        child_stale is not None or child_grew
        or (child_activity_age is not None and child_activity_age < 900))


def _idle_verdict(spinner):
    """`DONE_IDLE` requires a POSITIVE read that the screen is static.

    ⛔ THE FLEET'S STATED POLARITY IS `spinner is not False`, NOT TRUTHINESS (2026-10-13). An
    UNREAD screen (`None`) is not a weaker verdict — it is a DIFFERENT state, and the fleet's own
    contract says so (`docs/ops/fleet-liveness.md`: an unknown always carries a named reason,
    never a weaker `wedged`). At these return sites plain truthiness made `None` falsy, so a
    screen we could not read returned `DONE-IDLE` — a DISPATCH invitation, the exact action the
    read layer exists to make safe. The long-tool guard above already used the correct polarity;
    these sites were never brought to it. MEASURED: `classify(stale=1200, grew=False,
    spinner=None, ...)` -> `DONE-IDLE` before, -> `UNKNOWN` after.

    ⛔ WHAT ACTUALLY PROTECTS THE LANE — CORRECTED 2026-10-13. This docstring first claimed
    "`UNKNOWN` is not in `lane-actions.OFFERABLE`, so it routes to REPORT ONLY". That is FALSE of
    the consumer: `lane-actions.classify_row()` places every unresolved lane on `step="5"`, and
    `build()` then REPLACES the verdict with the JEV words-layer label — so a lane-status verdict
    is `why` TEXT, not the bucket. An unread screen can therefore still reach the beat's DO list;
    what stands in the way is the confidence floor (a low-confidence label is not emitted as an
    instruction) and `queue-dispatch.py`, which gates on this verdict directly. The routing gap is
    filed rather than papered over: the abstention here is still the correct producer behaviour,
    and it does bite for every consumer that reads the verdict directly.
    """
    if spinner is None:
        return UNKNOWN
    return WIP_IDLE if spinner else DONE_IDLE


def classify(stale, grew, spinner, last_kind, child, child_stale, child_grew,
             child_activity_age, tool_inflight, last_stop=None, has_sid=False,
             cpu_busy=None):
    # ── STEP 2 FIRST -- the doc's STRONGEST signal, and the only non-file, non-screen one ──
    # Ordered ahead of every proxy below because it is the one that cannot be fooled by a lane
    # executing a long tool call: such a lane writes nothing to its session (so `stale` climbs and
    # `grew` stays false) and, if it has no child and no spinner left on screen, it fell all the
    # way through to WEDGED/DONE-IDLE -- the two verdicts that mean "check the process" and
    # "hand it new work". `cpu_busy` is None unless attribution was EXACT (see lane_cpu_busy),
    # so a False here changes nothing and only a PROVEN True short-circuits.
    if cpu_busy:
        return WORKING
    if last_kind is None:
        # No session binding (or no records) -- which is NOT the same as the
        # pane having no session. Reported as unattributable, not as absent.
        #
        # ⛔ BUT TWO VERY DIFFERENT LANES LAND HERE, AND THEY NEED OPPOSITE TREATMENTS.
        # A session that RESOLVED and simply holds no events yet is a FRESH, IDLE, NEVER-TASKED
        # lane: `resolve_session` found it, the pane shows a live pi sitting at a prompt, and
        # nothing has ever been asked of it. A session that did NOT resolve is genuinely
        # unattributable. Collapsing both to UNBOUND is what made the fleet look starved while it
        # was not: the dispatcher only sends to DONE-IDLE, so a fresh lane was UNREACHABLE.
        # MEASURED 2026-10-04: 10 lanes read UNBOUND on exactly this signature -- each had a live
        # pi at an idle prompt (footer present, `0.0%`, no spinner) and a session id NEWER than the
        # orchestrator's own (`01a10486`, `01a10487` vs `01a102a3`), i.e. freshly relaunched panes
        # that had never received a task. `dispatched 0` was reported while 6 landing rows and 12
        # conflicts waited. `has_sid` is the fact that separates the two cases.
        #
        # ⛔ BUT `DONE-IDLE` HERE STILL REQUIRES A POSITIVE READ (2026-10-13). This FIFTH site was
        # missed when the tri-state landed: it returned the dispatchable verdict without consulting
        # `spinner` AT ALL, so an UNREADABLE screen on a session holding no parseable records still
        # invited a new task onto a lane whose state nobody read. Same absent-read-collapsed-to-a-
        # definite-value class as the four sites `_idle_verdict()` covers; found by review, not by
        # the tests. Measured: `classify(stale=None, grew=False, spinner=None, last_kind=None,
        # has_sid=True)` -> `DONE-IDLE` before, -> `UNKNOWN` after.
        return _idle_verdict(spinner) if has_sid else UNBOUND
    if grew:
        return WORKING
    # ⛔ A RECORD THAT KNOWS NOTHING ABOUT ITS CHILD MUST NOT DECIDE THE VERDICT.
    # An unmatched dispatch is evidence that a child was STARTED -- never, by itself, evidence about
    # what it is doing. When the child left no trace at all (no transcript, no on-disk effect, no
    # sampled growth), the parent's own state is the better witness and the parent-state logic below
    # must get to answer. MEASURED 2026-10-12, `Storage Archictecture`: a 35h-old abandoned record
    # with `child_stale=72195` and `child_activity=None` pinned the verdict at CHILD-STUCK while the
    # parent had written 86s earlier and was mid-`bash` -- a lane actively being driven, read as a
    # stuck child. It also silently disabled the long-tool-call guard below, which is gated on
    # `not child`. A genuinely quiet parent is still served: the `abandoned` clause at the bottom of
    # this function answers it with WAITING_OVERDUE, which lane-actions.py routes to REPORT ONLY.
    child_evidence = child_has_evidence(child, child_stale, child_grew, child_activity_age)
    # ⛔ A FRESH PARENT WRITE OUTRANKS A CHILD RECORD -- hoisted above the child inference
    # 2026-10-12. The pane retains its last frame, so a spinner glyph alone is not evidence of
    # activity; a session written in the last 90s IS. Measured that tick: `Storage Archictecture`
    # had written 86s earlier and held an in-flight `bash`, yet a 35h-old abandoned record with
    # `child_stale=72195` and no on-disk effect pinned it at CHILD-STUCK -- the verdict
    # lane-actions.py turns into "unblock it". A child INFERENCE may only speak about a lane that is
    # not itself writing; evidence about the parent beats an inference about a child we cannot see.
    # A hang is not lost by this: it is one tick old, and past 90s the child logic is reached anyway.
    if spinner and stale is not None and stale < 90:
        return WORKING
    # ── a long DIRECT tool call is not a wedge ────────────────────────────
    # ⛔ `spinner is not False`, NOT `spinner`: an UNREAD screen (`None`) must not be counted as
    # evidence of NO spinner. `tool_inflight` is itself strong evidence of a direct tool call, so
    # when the screen is unread we cannot rule the long tool OUT -- and the safe direction is to
    # keep the lane out of WEDGED. Only a screen that was READ and carries no spinner excludes it.
    # ⛔ ASKS ONLY ABOUT THE PARENT. It used to read `not (child and child_evidence)`, which had the
    # same defect as main's `ti` gate: `child_evidence` is true merely because the child has a
    # transcript, so the guard was SKIPPED for the exact abandoned-record cases it was written for.
    # A declared-budget tool in flight on the PARENT is the strongest available explanation of the
    # quiet, and no record about a child may suppress it. Verified against the pre-change
    # instrument on `Drain` (LONG-TOOL, not CHILD-STUCK).
    if tool_inflight and spinner is not False:
        age = tool_inflight.get("age")
        tmo = tool_inflight.get("timeout")
        if age is not None and tmo and age < tmo:
            return LONG_TOOL          # inside its own declared budget
        if age is not None and age < 900:
            return LONG_TOOL          # no budget declared, but not yet a suspect
    # ── child awareness: the case raw mtime gets WRONG ────────────────────
    # ⛔ A CHILD-STUCK verdict is a claim about the CHILD, and a quiet child under
    # an INACTIVE parent is explained by the PARENT: the lane stopped. Measured
    # 2026-09-26: `2c Pack compile` read CHILD-STUCK on three consecutive ticks
    # (46m / 79m / 91m) while its pane carried NO spinner and its session had not
    # been written for 28 minutes — because the lane had deliberately stopped on
    # load and said so in the pane ("Why I stopped short of implementing Stage 2 —
    # not a gate, budget and load ... a claim ahead of its evidence"). A quiet
    # child under a stopped parent is not a wedge; it is a lane at rest.
    #
    # So when the parent shows no activity at all, SKIP the child inference and let
    # the parent-state logic below decide -- it already separates a completed turn
    # from a wedge, and it is the code path that has been tested. Evidence about
    # the parent outranks an inference about a child we cannot see.
    parent_stopped = bool(
        child and child_stale is not None and child_stale > 900
        and not spinner and stale is not None and stale > 600
    )
    # ⛔ A RECORD THAT KNOWS NOTHING ABOUT ITS CHILD MUST NOT DECIDE THE VERDICT.
    # An unmatched dispatch is evidence that a child was STARTED -- never, by itself, evidence about
    # what it is doing. When the child left no trace at all (no transcript, no on-disk effect, no
    # sampled growth), the parent's own state is the better witness and the parent-state logic below
    # must get to answer. MEASURED 2026-10-12, `Storage Archictecture`: a 35h-old abandoned record
    # with `child_stale=72195` and `child_activity=None` pinned the verdict at CHILD-STUCK while the
    # parent had written 86s earlier and was mid-`bash` -- a lane actively being driven, read as a
    # stuck child. It also silently disabled the long-tool-call guard below, which is gated on
    # `not child`. A genuinely quiet parent is still served: the `abandoned` clause at the bottom of
    # this function answers it with WAITING_OVERDUE, which lane-actions.py routes to REPORT ONLY.
    # (`child_evidence` is computed above, before the long-tool guard that also needs it.)
    if child and child_evidence and not parent_stopped:
        # ⛔ A COMPLETED TURN OUTRANKS AN ABANDONED CHILD RECORD. An unmatched dispatch we cannot
        # vouch for is a stale RECORD, not evidence of a wait; if the lane's own last message is
        # the assistant ENDING its turn, the lane is idle and that record is history. Without
        # this, keeping abandoned records would resurrect the "a call from days ago makes a
        # healthy lane read CHILD-STUCK forever" failure the old discard was written to stop.
        if child.get("abandoned") and last_kind == "assistant" and last_stop == "stop":
            return _idle_verdict(spinner)
        if child_grew:
            return WAITING                      # parent idle, child healthy — correct
        if child_stale is not None:
            # The child's OWN transcript answered the question. This is evidence,
            # and it outranks every proxy below it: a child that wrote 86s ago is
            # alive no matter how long ago it was dispatched. Before this branch
            # existed, a fresh child_stale matched nothing and fell through to
            # `age > OVERDUE_S`, so `5&9 MCP and SDK surface` read CHILD-OVERDUE
            # while its child was demonstrably writing.
            if child_stale > 900:
                # A quiet transcript is NOT evidence of a stall -- the heartbeat's
                # own WEDGED caveat says exactly this ("a long tool call writes
                # nothing until it returns"). Ask the child's on-disk effect
                # before asserting a diagnosis about it. Measured 2026-09-26: two
                # lanes read CHILD-STUCK (transcript quiet 101m / 125m) while
                # their children were writing a 112 KB test file and rotating
                # bash pids the entire time.
                if child_activity_age is not None and child_activity_age < 900:
                    return WAITING              # quiet transcript, but progress on disk
                return CHILD_STUCK              # persisted child, quiet AND idle on disk
            return WAITING                      # measured fresh — alive
        # No transcript to read: judge by the child's on-disk effect, then by
        # elapsed time against the harness's own 20-min in-flight bound. This is
        # the UNVERIFIABLE path -- the verdict is a guess about a child we cannot
        # see, so it must not be reported as a fact about the child.
        if child_activity_age is not None and child_activity_age < 900:
            return WAITING                      # the child is demonstrably still writing
        if child["age"] is not None and child["age"] > OVERDUE_S:
            return WAITING_OVERDUE              # past the watchdog's own bound
        return WAITING
    if stale is not None and stale > 600:
        # ── a COMPLETED turn is IDLE, never a wedge ──────────────────────────
        # The pane retains its last frame, spinner glyph included, so a static
        # glyph beside a quiet session is EXACTLY what a finished lane looks
        # like -- yet it produced WEDGED, whose meaning is "check the process".
        # `stopReason` is the discriminator the glyph cannot supply: "stop" is
        # the model ending its turn deliberately, "toolUse" is a call still
        # owed a result. Measured 2026-09-26: `2c Pack compile` and `5&9 MCP
        # and SDK surface` both read WEDGED off completed reports (4h37m and
        # 1h24m quiet) that read "Blocked on the owner" and "Lane report:" --
        # two lanes flagged for attention every tick of a shift for being done.
        if last_kind == "assistant" and last_stop == "stop":
            return _idle_verdict(spinner)
        # ⛔ AN OUTSTANDING DISPATCH IS NOT A WEDGE (2026-10-12). WEDGED's instruction is "check
        # the process", and its measured cost is a kill/respawn of a HEALTHY lane. We arrive here
        # holding an unmatched `task`/`subagent` call and no usable child evidence -- i.e. we know
        # a dispatch was made and we do NOT know what became of it. That is exactly
        # CHILD-OVERDUE's meaning ("UNMATCHED, not proven cut"), and lane-actions.py already routes
        # it to REPORT ONLY, so the owner still sees it and no kill is invited.
        if (tool_inflight and tool_inflight.get("name") in TOOL_NAMES) \
                or (child and child.get("abandoned")):
            return WAITING_OVERDUE
        if spinner is None:
            return UNKNOWN          # unreadable screen: abstain (was DONE-IDLE — a dispatch invite)
        return WEDGED if spinner else DONE_IDLE
    if last_kind == "user":
        return WIP_IDLE
    if last_kind == "tool":
        return WORKING
    if last_kind == "assistant":
        return _idle_verdict(spinner)
    return UNKNOWN


def _publish_snapshot(out, cache_path, key):
    """Write the machine snapshot to `cache_path` — but NEVER a degraded one.

    ⛔ A DEGRADED READ MUST NOT BECOME A STICKY FAILURE (2026-10-12, measured). Caching a degraded
    snapshot for the 420 s TTL makes ONE failed read poison every consumer for the rest of the
    window: after the launchd PATH bug was fixed, `--json` STILL returned 27/27 degraded rows until
    the TTL expired, and `lane-actions.py` refuses degraded snapshots — so `pr-doctor` stayed unable
    to dispatch on a fleet it could no longer see. Cache a SUCCESS or nothing: a missing cache costs
    one real scan, which is the safe direction. Returns True iff a snapshot was written.
    """
    if not out:
        # ⛔ AN EMPTY SNAPSHOT IS NOT A HEALTHY FLEET (2026-10-13). `degraded` is a PER-ROW flag, so
        # on an empty row set `any(...)` is vacuously False and this publisher cached `[]` — exactly
        # what a COMPOUND failed read produces (registry unreadable AND cmux unreadable). Caching it
        # presents an empty fleet as a FRESH published read for the whole TTL, and the freshness
        # test (`-s "$SNAP"`) then refuses to launch the fallback scan: the fleet goes DARK while
        # every read-quality flag says healthy. A missing cache costs one real scan.
        return False
    if any(isinstance(r, dict) and r.get("degraded") for r in out):
        return False
    _tmp = cache_path + ".tmp"
    with open(_tmp, "w") as fh:
        json.dump({"key": key, "t": time.time(), "out": out}, fh, default=str)
    os.replace(_tmp, cache_path)   # atomic: a reader never sees a half-written snapshot
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--sample", type=float, default=18.0)
    # ⛔ `--only` EXISTS TO BOUND A CALLER'S COST, NOT FOR CONVENIENCE.
    # MEASURED 2026-10-04: one full read costs ~250-300s at fleet load, because it makes ~2 cmux
    # subprocess calls per lane across 29 lanes. queue-dispatch.py reads TWICE per pass (the
    # two-read guard) and its whole pass budget is pinned to the owner's 5-9 min cadence, so it was
    # spending ~600s on reads alone and being killed before it dispatched anything --
    # `STALL queue-dispatch.py ... and was killed (rc=143)`, twice measured, with `dispatched 0`.
    # The second read only needs to guard the lanes about to be examined (--max-lanes), not all 29,
    # and `safe-send.sh`'s lane-guard remains the AUTHORITATIVE check at the moment of sending, so
    # nothing is weakened: the guard is still performed, just not redundantly fleet-wide.
    ap.add_argument("--only", default=None,
                    help="comma-separated lane labels: probe only these (bounds the cost)")
    ap.add_argument("--no-cache", action="store_true",
                    help="force a real scan (the tick's pass-opening read uses this)")
    a = ap.parse_args()

    # ── ONE SNAPSHOT PER PASS (2026-10-05) ────────────────────────────────────────────────
    # MEASURED: this scan costs 91s at current load (17 cmux calls; the `--only` note below records
    # ~250-300s under heavy load), and ONE heartbeat pass ran it THREE times -- the tick's own read
    # (`--sample 12`), then lane-triage.py's, then turn-classify.py's -- roughly 273s of identical
    # work inside a 540s pass. That is why the tick kept dying at its own bound (`STALL
    # orchestrator-heartbeat.sh exceeded 390s`) even after the pane probes were bounded: the budget
    # was never the problem, the DUPLICATION was.
    #
    # The risk of a cache is not that it is old -- it is that the PASS-OPENING read is old, because
    # every later decision in that pass would inherit it. So the tick's own call passes
    # `--no-cache` and is always real; every other consumer in the same pass reuses a snapshot
    # taken seconds earlier. TTL 420s is longer than the steps that follow within a pass and
    # shorter than the 540s cadence, so a cache can never span two passes even if a caller forgets.
    if a.json and not a.no_cache:
        try:
            # KEYED ON --only, DELIBERATELY NOT ON --sample (2026-10-05). The sample is a DURATION
            # (how long to watch), not a selector: the three consumers in one pass ask for
            # different durations -- the tick for 12, the triage and turn-classify for 0 -- so
            # including it in the key made every consumer MISS and re-run the 104s scan, which is
            # the duplication this cache exists to remove. The snapshot they need is the same one;
            # a longer sample is simply better data, and the tick pass-opening read is always real
            # (`--no-cache`), so a shallow early snapshot can never be handed to it.
            _ck = json.dumps([a.only])
            _cf = os.path.join(os.path.expanduser("~/.pi/agent/state"), "lane-status.cache")
            with open(_cf) as fh:
                _c = json.load(fh)
            if _c.get("key") == _ck and (time.time() - _c.get("t", 0)) < 420:
                print(json.dumps(_c.get("out"), indent=2, default=str))
                return 0
        except Exception:
            pass      # a broken or absent cache must never break the scan -- fall through to a real read

    rows = registry()
    # ⛔ AN EMPTY ROSTER IS NOT AN ANSWER, AND `registry()` CAN RETURN ONE (2026-10-13). The
    # docstring on `_tsv_rows()` (and a test docstring) asserted that "returning nothing lets `main()`
    # hit its own `if not rows: raise`". No such guard existed here — `grep -n 'not rows'` matched
    # only `_live_workspaces()`. So the COMPOUND failure (registry unreadable AND cmux unreadable)
    # produced `rows=[]`, printed `[]`, exited 0, and cached it: a healthy-looking EMPTY fleet. The
    # two artifacts that claimed this guard existed were false; one of them was written by the same
    # change that added `_tsv_rows`'s `except OSError`. Enforce it here, and refuse to publish.
    if not rows:
        sys.stderr.write(
            "lane-status: REFUSING — the roster is EMPTY (registry unreadable and/or the cmux read\n"
            "  failed). An empty fleet is not a read; publishing it would make the fleet look\n"
            "  healthy-and-idle for the whole cache TTL. Check ~/.pi/agent/state/lane-registry.tsv\n"
            "  and the cmux socket.\n")
        raise SystemExit(3)
    if a.only:
        _want = {x.strip().lower() for x in a.only.split(",") if x.strip()}
        rows = [r for r in rows
                if r[0].strip().lower() in _want
                or r[0].strip().lower().split(" (")[0] in _want]    # ⛔ DO NOT PARALLELISE THIS LOOP. I TRIED IT AND IT MADE THINGS WORSE.
    # MEASURED 2026-10-04: wrapping resolve_session() in a ThreadPoolExecutor(max_workers=8) took
    # the tool from **167s to 283s** -- a 70% REGRESSION. The pane-screen loop below IS
    # parallelised and that was a measured win, so the obvious inference was that this loop was
    # an oversight of the same kind. It is not: cmux evidently serialises these calls internally
    # (or the load on this box turns 8-way contention into pure overhead), so concurrency here
    # buys nothing and costs a lot. The difference from the screen loop is that the screen win was
    # MEASURED before it was written and this one was ASSUMED. Reverted. If someone wants this
    # faster, profile cmux itself first; do not reintroduce threads on the strength of the
    # similarity to the loop below.
    snap = {}
    for label, ws, _il in rows:
        sid, _verified = resolve_session_ex(ws)
        f = session_file(sid)
        child, cf = most_live_child(pending_children(f) if f else [], exclude=f)
        snap[label] = dict(ws=ws, sid=sid, verified=_verified, file=f,
                           size=os.path.getsize(f) if f else None,
                           child=child, child_file=cf,
                           child_size=os.path.getsize(cf) if cf else None)
    # ── STEP 2 SAMPLE WINDOW: cumulative CPU TIME, taken across the SAME sleep the file
    # probes use, so every signal in one verdict describes one interval (the doc requires two
    # samples ~25s apart; `--sample` is 18s by default and is the window this file already owns).
    cpu0 = _pi_cpu_map()
    time.sleep(a.sample)
    cpu1 = _pi_cpu_map()
    # Attribute pids to lanes by the sessions-dir mangling of their cwd. Built ONCE, and used
    # only through lane_cpu_busy()'s strict exactly-one-both-sides rule.
    _dir_lanes, _dir_pids = {}, {}
    for _lbl, _ws, _il in rows:
        _f = snap[_lbl]["file"]
        if _f:
            _dir_lanes.setdefault(os.path.basename(os.path.dirname(_f)), []).append(_lbl)
    for _pid, _cwd in _pi_cwd_map().items():
        try:
            _d = "--" + _cwd.strip("/").replace("/", "-") + "--"
        except Exception:
            continue
        _dir_pids.setdefault(_d, []).append(_pid)

    # ── PREFETCH THE PANE SCREENS IN PARALLEL ────────────────────────────────
    # MEASURED 2026-10-01: this loop read each pane SERIALLY. At fleet load one
    # `cmux read-screen` costs ~10-15s, so a whole run reached 371s for 27 lanes
    # (65s when the box was quiet). queue-dispatch.py reads this tool with a 300s
    # timeout, so the read TIMED OUT and the dispatcher printed "dispatchable: 0 /
    # dispatched 0" -- no lane was fed while the fleet looked fed. The calls are
    # independent, so fetch them concurrently: same data, ~8x less wall time.
    _screens = {}
    _need = [ws for label, ws, ilabel in rows if snap[label]["sid"]]
    if _need:
        try:
            from concurrent.futures import ThreadPoolExecutor
            with ThreadPoolExecutor(max_workers=8) as _ex:
                for _ws, _scr in zip(_need, _ex.map(read_screen, _need)):
                    _screens[_ws] = _scr or ""
        except Exception:
            _screens = {}   # fall back to the serial path below, never to no screen

    out = []
    for label, ws, ilabel in rows:
        s = snap[label]
        f = s["file"]
        grew, stale = False, None
        if f:
            try:
                grew = s["size"] is not None and os.path.getsize(f) > s["size"]
                stale = int(time.time() - os.path.getmtime(f))
            except Exception:
                pass
        # one screen read, used twice: the spinner and the child lines.
        # The spinner is judged on the BOTTOM 12 lines only -- reading the full
        # 80-line window for the child parse would match a stale "Working" left
        # higher in the scrollback and turn a DONE-IDLE lane into a WEDGED one.
        screen = ((_screens[ws] if ws in _screens else read_screen(ws))
                  if s["sid"] else "")
        # ── TRI-STATE, AND THE THIRD VALUE IS THE POINT ──────────────────────────────────
        # `"Working" in ""` is False, so ANY empty read became a confident "this lane shows no
        # spinner" -- an absent signal rendered as a definite value. MEASURED 2026-10-11: 15 of 32
        # rows are empty reads, and the cause is NOT load, it is that the WORKSPACE IS GONE:
        #   `cmux read-screen --workspace <dead-id>` prints `Error: not_found: Workspace not found`
        #   on STDERR, writes 0 bytes to STDOUT, and exits 0 -- so `sh()` (stdout only) sees "", and
        #   the exit code cannot distinguish it either.
        # 15/15 of those rows also report `inbound=-` (cmux read OK, no record), and 0/17 of the rows
        # with a real screen do -- so an empty screen is a reliable proxy for a dead workspace.
        # A live pi pane always draws a status line, so an empty screen is NEVER a blank pane.
        #   True  = the screen says Working
        #   False = the screen was READ and carries no spinner
        #   None  = the screen could not be read -- UNKNOWN, and nothing follows from it
        _sc = screen if isinstance(screen, str) else ""
        spinner = None if not _sc.strip() else ("Working" in "\n".join(_sc.splitlines()[-12:]))
        # NOTE the 3600s bound. The pane line's PRESENCE is the liveness signal --
        # pi prints it while the child runs and redraws the screen as the spinner
        # animates. Filtering it on a 900s transcript age was wrong: a child inside
        # a long tool call writes nothing, so it was discarded exactly when we
        # needed it (measured 2026-09-26, `7 Instrumentation` read CHILD-STUCK off
        # a 28m-quiet pending child while its pane showed a live child and an
        # animating spinner). The bound is kept only to expire a genuinely stale
        # frame, which is why it is generous rather than tight.
        pane_kids = ([k for k in parse_child_lines(screen) if k["age"] < 3600]
                     if s["sid"] else [])
        recs = tail(f, 8) if f else []
        descs = [(k, t) for k, t in (describe(r) for r in recs) if k != "other"]
        last_kind, _ = descs[-1] if descs else (None, "")
        # The stop reason of the LAST record, and only when that record is the
        # assistant's own. A trailing toolResult must not inherit the stop
        # reason of the message that requested the call, so this is guarded on
        # the role rather than read from the last record unconditionally.
        last_stop = None
        if recs:
            _last_msg = recs[-1].get("message") or {}
            if _last_msg.get("role") == "assistant":
                last_stop = _last_msg.get("stopReason")

        # ── child: did it move during the SAME sample window as its parent? ──
        child = s["child"]
        child_file = s["child_file"]
        child_stale = child_grew = child_act = None
        if child_file:
            try:
                csz = os.path.getsize(child_file)
                child_stale = int(time.time() - os.path.getmtime(child_file))
                child_grew = csz > (s["child_size"] or 0)
            except Exception:
                child_file = None
        # On-disk effect is the only signal that survives a long tool call: a
        # child inside one writes nothing to its transcript until the call
        # returns, so transcript quiet alone cannot justify CHILD-STUCK. Computed
        # only where it can change the verdict (no transcript, or a quiet one),
        # because this walk is the most expensive thing in this file.
        if child and (not child_file or (child_stale is not None and child_stale > 900)):
            child_act = child_activity(child["cwd"])

        # a direct tool still in flight, with its own declared budget
        # ⛔ THE PARENT'S OWN IN-FLIGHT TOOL, READ WITHOUT REFERENCE TO ANY CHILD -- see
        # `in_flight_tool` for the measured regression this shape makes impossible. (`child_has_evidence`
        # is still what decides the child branch in `classify()`.)
        ti = in_flight_tool(f)

        _cpu = lane_cpu_busy(label, s["file"], _dir_lanes, _dir_pids, cpu0, cpu1)
        verdict = classify(stale, grew, spinner, last_kind, child, child_stale,
                           child_grew, child_act, ti, last_stop=last_stop,
                           has_sid=bool(s["sid"]), cpu_busy=_cpu)
        # ── children the lane launched OUTSIDE its own root ──────────────────
        # Nothing inside the root moves while they work, so the lane reads
        # DONE_IDLE -- and DONE-IDLE tells the reader to dispatch it, which
        # duplicates live work. Measured 2026-09-25: `3 Onboarding` read
        # DONE-IDLE with three live declared `pi` children and two open PRs.
        declared = declared_children(label)
        # A lane with a LIVE child is waiting on it -- never idle, never wedged, and
        # never "stuck". The pane is authoritative and covers OUT-OF-ROOT children,
        # which is the case the cwd-based `pending_child` cannot see. CHILD_STUCK is
        # in this list deliberately: measured 2026-09-26, `5&9` read CHILD-STUCK off
        # a 27m-old pending child while its pane showed TWO live children (451s,
        # 554s) -- the lane was demonstrably waiting on live work, and the stale
        # pending entry was a different, older child.
        # ── THE LANE'S OWN TRANSCRIPT IS THE AUTHORITATIVE CHILD SOURCE ───────
        # `child` comes from pending_child(), which reads THIS lane's session file: a `task`/
        # `subagent` toolCall with NO matching toolResult. That is EXACT attribution -- unlike the
        # cwd-based `child_file` walk or a pane parse, it cannot steal a sibling's child, because
        # the record is the lane's own.
        #
        # ⛔ MEASURED 2026-10-11 -- why neither existing source could see a modern `task` child,
        # and why this clause is the fix rather than a fourth signal:
        #   * parse_child_lines matches `[task] child session <id> -> <dir>`. The pane does NOT
        #     render that; it renders a bare ` task` row (verified on three panes, incl. one with
        #     FOUR ` task` rows, some historical). So pane_kids was ALWAYS [].
        #   * declared_children reads the legacy /tmp/<prefix>-*.pid convention: 30 pid files
        #     against 21 live lanes, none of them for the affected lanes. So declared was ALWAYS [].
        #   * independently measured: SIX live session files carried an unmatched `task` toolCall
        #     at the same moment -- the signal was present and simply unread.
        # Therefore `(declared or pane_kids)` was False on every lane running a `task` child and
        # the suppression below could not fire. Four false verdicts in one evening (Storage
        # Architecture IDLE->WITHHELD, tortoise-sweep WEDGED, 2b Extractor STALL, 3 Onboarding
        # STALL), two of them while the pane showed a live child. WEDGED is the costly one: its
        # instruction invites a kill/respawn of a HEALTHY lane.
        #
        # The bound is ABANDON_S, the SAME one pending_child already applies.
        # ⛔ CORRECTED 2026-10-13 — THIS COMMENT USED TO STATE THE PREMISE THAT `ABANDON_S`'s OWN
        # DOCSTRING RETRACTS. It read: "a `task` child cannot outlive the harness's in-flight
        # bound, so past it the open call is a stale RECORD". That is FALSE of the artifact and
        # measured false in production (three `task` children alive and running pytest at 2h26m, a
        # child polling CI at 1h30m) — the measurement is in `pending_children()`'s docstring, which
        # states the retraction. ⚠️ This pointer first read "30 lines above": it was wrong by ~1787
        # lines, and a mis-located retraction is exactly how the premise gets re-derived backwards. What actually makes an old record safe to discount here is that the
        # child's OWN transcript and on-disk effect are consulted FIRST
        # (`most_live_child` / `child_suppresses`) — not the mere passage of time.
        # and must not mask a real wedge. Absence is preferred to a wrong class everywhere else in
        # this test -- here too: a missing child_file (child_stale is None) does NOT count against
        # the child, because an unreadable stat is not evidence the child is dead.
        # ── INBOUND-RECENCY: a PRIOR, not a liveness proof (owner 2026-10-11, corrected) ───
        # `None` abstains. The AGE is reported on every row because it is the discriminator: a
        # lane whose last inbound is hours old AND that shows no output is the suspicious one.
        _se, inbound_readable = _submitted_epoch(ws)
        inbound_age = None if _se is None else int(time.time() - _se)
        # The MESSAGE is surfaced for one reason: a RECENT-INBOUND suppression is otherwise
        # INAUDITABLE. The prior fires when a lane was told something and has not answered, and a
        # reader who cannot see WHAT it was told cannot tell "work just assigned, leave it alone"
        # from "a question that went unanswered" -- opposite actions from the same verdict.
        inbound_msg = _inbound_message(ws)
        # ── BOTH PRIORS ARE EVALUATED AGAINST THE CLASSIFIER'S OWN VERDICT ──────────
        # ⛔ NOT AGAINST EACH OTHER'S OUTPUT. Evaluating the second against the first's result is
        # what made the inbound prior DEAD CODE: `child_suppresses` rewrites `verdict` to
        # WAITING-CHILD, `WAITING-CHILD` is not in `INBOUND_DISCOUNTS`, and so the inbound check
        # could never fire. MEASURED 2026-10-11: FOURTEEN live lanes carried a fresh inbound
        # (<= INBOUND_FRESH_S) and ZERO produced RECENT-INBOUND. Each prior is a statement about the
        # SAME original classification, so both read it; the child prior has precedence when both
        # apply, because a live child is OUTPUT evidence while an inbound is only an INPUT event.
        _base_verdict = verdict
        if child_suppresses(_base_verdict, declared, pane_kids, child, child_stale):
            verdict = WAITING
        elif inbound_discounts_idle(_base_verdict, inbound_age, stale):
            verdict = WAITING_INBOUND        # `size` is the session file's CURRENT byte length, and it is the
        # fingerprint turn-end.py keys on: a lane that has taken a turn has a
        # bigger file; one that is sitting still has the same number. That is
        # how "nudge once per idle episode" is enforced with no database — the
        # file size IS the memory (same trick as the label on the question gate).
        cur_size = None
        if f:
            try:
                cur_size = os.path.getsize(f)
            except Exception:
                cur_size = s["size"]
        out.append(dict(lane=label, verdict=verdict, stale_s=stale, grew=grew,
                       inbound_age=inbound_age, inbound_readable=inbound_readable, cpu=_cpu,
                       inbound_msg=inbound_msg,
                       # ── THE TWO READ-QUALITY FLAGS, ON EVERY ROW ──────────────────────
                       # Neither is a verdict. `degraded` says the FLEET ROSTER could not be
                       # read, so this row set is the hand-written TSV and every live-only lane
                       # is missing (a consumer must REFUSE, not act). `session_verified` says
                       # whether the session id under this row was confirmed as the one being
                       # written; when it is False the verdict is built on an id we could not
                       # check, so it must ABSTAIN rather than assert an idle lane.
                       degraded=(LIVE_READABLE is False),
                       session_verified=s.get("verified"),
                       declared=declared, pane_children=pane_kids,
                        spinner=spinner, sid=s["sid"], ws=s["ws"], size=cur_size,
                        issue_label=ilabel,
                        last=(last_kind or "-"),
                        recent=[f"{k}:{t[:66]}" for k, t in descs[-3:]],
                        child=child, child_file=os.path.basename(child_file) if child_file else None,
                        child_stale=child_stale, child_grew=child_grew,
                        child_activity=child_act, tool=ti))

    if a.json:
        _blob = json.dumps(out, indent=2, default=str)
        # ALWAYS WRITE, EVEN UNDER --no-cache (2026-10-05). The first cut guarded this with
        # `if not a.no_cache:` and so the flag meant "do not read AND do not write" -- the tick
        # pass-opening scan cached nothing, and every later consumer in the same pass missed and
        # re-ran the full scan. MEASURED: 104s per miss, three times a pass, i.e. the exact cost
        # this cache exists to remove, reproduced by its own flag. `--no-cache` means "do not
        # READ": force this call to be a real scan, and publish the result for the rest of the
        # pass. A caller that wants no cache at all is not a case the wake-up path has.
        try:
            _cf = os.path.join(os.path.expanduser("~/.pi/agent/state"), "lane-status.cache")
            _publish_snapshot(out, _cf, json.dumps([a.only]))
        except Exception:
            pass      # caching is an optimisation; failing to cache must not fail the scan
        print(_blob)
        return

    order = {CHILD_STUCK: 0, WAITING_OVERDUE: 1, WEDGED: 2, EMPTY: 3, UNBOUND: 3,
             WIP_IDLE: 4,
             LONG_TOOL: 5, WAITING: 6, DONE_IDLE: 7, WORKING: 8, UNKNOWN: 9}
    out.sort(key=lambda r: order.get(r["verdict"], 9))
    print(f"{'LANE':<26} {'VERDICT':<14} {'SELF':>7} {'UI':<8} {'INBOUND':>10}  CHILD / LAST")
    print("-" * 106)
    for r in out:
        st = "-" if r["stale_s"] is None else (
            f"{r['stale_s']//3600}h{(r['stale_s']%3600)//60:02d}m" if r["stale_s"] >= 3600
            else f"{r['stale_s']//60}m{r['stale_s']%60:02d}s" if r["stale_s"] >= 60
            else f"{r['stale_s']}s")
        # An UNREAD screen must not print the same glyph as a READ one carrying no spinner:
        # `-` is a claim ("read, no spinner"); the unread case is the absence of a claim.
        ui = {True: "Working", False: "-", None: "UNREAD"}[r["spinner"]]
        extra = r["last"]
        if r.get("tool") and not r["child"]:
            t = r["tool"]
            a = (t.get("age") or 0) // 60
            extra = f"{t['name']} in flight {a}m"
            if t.get("timeout"):
                extra += f" (declared {t['timeout']}s)"
        elif r["child"]:
            c = r["child"]
            age = c["age"] or 0
            bits = f"child {age//60}m"
            if r.get("child_activity") is not None:
                bits += f" disk-write={r['child_activity']//60}m ago"
            elif r.get("child_stale") is not None:
                bits += f" last-write={r['child_stale']//60}m"
            if age > OVERDUE_S:
                bits += " ⚠️ past 20m harness bound"
            extra = f"{bits} :: {c['task'][:40]}" if c["task"] else bits
        _sa = r.get("inbound_age")
        # ⛔ Show the inbound TEXT only where it explains something -- on a RECENT-INBOUND
        # suppression. Everywhere else the age is enough, and a message on every line would bury
        # the column that matters. `inbound=-` / `inbound=UNREAD` are left alone: there is no
        # message to show and inventing a rendering for one would fake the absent signal.
        if r["verdict"] == WAITING_INBOUND and r.get("inbound_msg") and _sa is not None:
            extra = f"told {_sa//60}m{_sa%60:02d}s ago: {r['inbound_msg']}" if (_sa or 0) >= 60 \
                else f"told {_sa}s ago: {r['inbound_msg']}"
        if not r.get("inbound_readable", False):
            _sub = "inbound=UNREAD"          # cmux itself could not be read
        elif _sa is None:
            _sub = "inbound=-"               # read OK; this lane has no inbound record
        elif _sa >= 3600:
            _sub = f"inbound={_sa//3600}h{(_sa%3600)//60:02d}m"
        elif _sa >= 60:
            _sub = f"inbound={_sa//60}m{_sa%60:02d}s"
        else:
            _sub = f"inbound={_sa}s"
        print(f"{r['lane']:<26} {r['verdict']:<14} {st:>7} {ui:<8} {_sub:>10}  {extra}")
        for line in r["recent"]:
            print(f"{'':<26} {'':<12} {'':>7} {'':<8}   · {line}")
    print()
    print("  " + " · ".join(f"{k}={v}" for k, v in sorted(Counter(
        r["verdict"] for r in out).items())))


if __name__ == "__main__":
    main()
