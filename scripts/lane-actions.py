#!/usr/bin/env python3
"""lane-actions.py -- the lane classification as a DETERMINISTIC process whose output is two lists.

WHY THIS EXISTS (owner, 2026-10-05)
-----------------------------------
The orchestrator was hand-classifying ~29 lanes every heartbeat by opening panes, which is slow,
non-repeatable, and done by an expensive LLM session. The owner asked for it to be an automatic
process -- "deterministic code + Jev" -- whose OUTPUT is handed to the agent:
  LIST 1 -- idle lanes that need a dispatch, WITH THEIR LAST MESSAGE
  LIST 2 -- wedged lanes to unblock, with WHY
This file is that process. It is the dispatcher's input, not a report about a report.

IT IMPLEMENTS state/LANE-STATE-DECISION-TREE.md, IN ITS ORDER
-----------------------------------------------------------
Step 0 identity -> Step 1 process exists -> Step 2 CPU-TIME DELTA (strongest) -> Step 3 child in
flight -> Step 4 age of the last tool call -> Step 5 read what it said. Only Step 5 yields meaning,
and it is where Jev belongs; Steps 2-4 exist to decide whether Step 5 is even needed.

EVERY MECHANICAL SIGNAL IS TAKEN FROM scripts/lane-status.py, WHICH IS NOT REWRITTEN HERE.
`lane-status.py` already diffs cumulative `ps -o time` (never `ps -o pcpu`, a lifetime average), and
`lane_cpu_busy()` already refuses to attribute a pid unless EXACTLY one lane maps to EXACTLY one
process. This file consumes its JSON and reuses its `session_file()` / `tail()` / `describe()` /
`_pi_cwd_map()` so there is ONE implementation of each mechanic.

WHAT IS DETERMINISTIC AND WHAT IS NOT
-------------------------------------
  deterministic (code): identity, existence, CPU delta, child in flight, tool age, PROTECTED
                        exclusion, BUSY (auto-nudged) suppression, the two lists
  Jev (one call, batched): ONLY the Step-5 words layer -- CONTINUE / BLOCKED_* / DONE_READY /
                        STALLED. One `choice` question per lane, all answered in ONE round trip
                        (the shape state/lane-verdict.py already uses; its key loader and its
                        criteria text are REUSED here rather than re-integrated).
Jev NEVER decides Steps 1-4 and NEVER overrides them: a lane proven WORKING by CPU time is not sent
to it at all.

FAIL-SAFE DIRECTIONS (each one chosen, not defaulted)
----------------------------------------------------
  * Jev unreachable  -> the words layer is UNREAD, so those lanes go to REPORT ONLY as
    UNCLASSIFIED(JEV-DOWN). They are NEVER guessed into "needs dispatch" or "wedged" -- acting on
    an unread word layer is exactly the failure the tree names.
  * process map lossy/empty -> existence is UNKNOWN, never DEAD. A false DEAD prescribes a
    relaunch, which REPLACES the pane command.
  * shared session id -> AMBIGUOUS-IDENT, report only. Two panes bound to one session file means
    neither lane's staleness/CPU reading is demonstrably about it (Step 0).
  * PROTECTED (DMeer / DMer / HANG) -> never offered as work, never nudged; listed with the reason.
  * BUSY (already auto-nudged, result SENT/QUEUED within the hour) -> never offered as work.

OUTPUT
------
  state/NEEDS-ACTION.md   -- the two lists + a REPORT ONLY section, each entry carrying
                             `- <lane> [<verdict>] (<age>) [<ws-uuid>] -- <last message ~200c>`
  stdout, ONE line        -- the beat's clause, e.g.
      IDLE->2 need dispatch (state/NEEDS-ACTION.md): laneA, laneB | WEDGED->1: laneC
  The beat is ONE line near its display limit, so the detail goes to the FILE and the beat carries
  the short pointer -- names inline, messages in the file. NO embedded newline is ever printed.

Usage:
  lane-actions.py                       # invoke lane-status.py --json (cache-aware), write the file
  lane-status.py --json | lane-actions.py --stdin -
  lane-actions.py --stdin state/lane-status.last.json
  lane-actions.py --json                # machine-readable result on stdout, file still written
  lane-actions.py --no-jev              # deterministic only (words layer marked UNREAD)
"""
import argparse
import glob
import importlib.util
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
STATE = os.path.join(HOME, ".pi", "agent", "state")
SCRIPTS = os.path.join(HOME, ".pi", "agent", "scripts")
LS_PATH = os.path.join(SCRIPTS, "lane-status.py")
LV_PATH = os.path.join(STATE, "lane-verdict.py")
REG_PATH = os.path.join(STATE, "lane-registry.tsv")
OUT_PATH = os.path.join(STATE, "NEEDS-ACTION.md")
BEAT_PATH = os.path.join(STATE, "NEEDS-ACTION.beat")


def display_path(p):
    """A path a reader can act on. The beat is read in a terminal whose cwd is the agent home, so
    `state/NEEDS-ACTION.md` is the useful form -- a bare basename makes the pointer ambiguous."""
    ap = os.path.abspath(p)
    agent_home = os.path.join(HOME, ".pi", "agent")
    return os.path.relpath(ap, agent_home) if ap.startswith(agent_home + os.sep) else ap
TURN_END = os.path.join(STATE, "turn-end")

# Copied from the two files this consumes, as CONSTANTS with the same meaning. Changing one without
# the other is the two-names-for-one-lane defect the registry header warns about, so they are named
# here with their source.
OVERDUE_S = 25 * 60            # lane-status.py OVERDUE_S: the harness's in-flight silence bound
PANE_CHILD_LIVE_S = 25 * 60    # a pane-drawn child younger than this is inside the same bound
TOL_CPU_S = 0.10               # lane-status.py lane_cpu_busy(): the stated CPU-time tolerance
COLD_MIN = 2 * 60              # decision tree Step 4: "< 2 min -> TOOL-IN-FLIGHT"
WARM_MIN = 10 * 60             # decision tree Step 4: "> 10 min -> STEP 5"
NUDGE_SUPPRESS_S = 3600        # orchestrator-heartbeat.sh NUDGE_SUPPRESS_S
REGISTRY_GRACE = 6             # a snapshot with fewer lanes than registry-grace is PARTIAL
PROTECTED = ("DMeer", "DMer", "HANG")   # the owner's own lanes: never offered as work
MAX_NAMES = 4                  # names inline in the beat clause; the rest live in the file
SUMMARY_MAX = 300
LAST_MSG_CHARS = 200


# ── module loading (reuse, do not rewrite) ────────────────────────────────────────────────
def _load(path, name):
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


# ── small helpers ─────────────────────────────────────────────────────────────────────────
def _age(s):
    if s is None:
        return "-"
    s = int(s)
    if s >= 3600:
        return "%dh%02dm" % (s // 3600, (s % 3600) // 60)
    if s >= 60:
        return "%dm" % (s // 60)
    return "%ds" % s


def _oneline(t):
    return " ".join((t or "").replace("\n", " ").split())


def _clip(t, n):
    t = _oneline(t)
    return t if len(t) <= n else t[: n - 1].rstrip() + "\u2026"


def _registry_labels():
    out = []
    try:
        with open(REG_PATH, errors="ignore") as fh:
            for ln in fh:
                if not ln.strip() or ln.startswith("#") or "\t" not in ln:
                    continue
                out.append(ln.split("\t")[0].strip())
    except OSError:
        pass
    return out


def _busy_sids():
    """Session ids whose turn was already auto-nudged (SENT/QUEUED within the hour).

    Same rule and same shared marker directory as orchestrator-heartbeat.sh: a lane the nudger has
    already told to continue is WORKING, so it must not be offered again.
    """
    out = set()
    try:
        for f in os.listdir(TURN_END):
            if not f.endswith(".json"):
                continue
            p = os.path.join(TURN_END, f)
            try:
                if time.time() - os.path.getmtime(p) > NUDGE_SUPPRESS_S:
                    continue
                d = json.load(open(p))
            except Exception:
                continue
            if str(d.get("result") or "").upper().startswith(("SENT", "QUEUED")):
                out.add(d.get("sid"))
    except OSError:
        pass
    return out


# ── STEP 1: does the process exist? (strict attribution or NO SIGNAL) ──────────────────────
def dead_lanes(rows, LS):
    """(set of lane labels with no live pi, reason string).

    The tree's Step 1 is the ONLY place a lane is called DEAD, and a false DEAD prescribes a
    relaunch that REPLACES the pane command -- so this refuses to answer unless attribution is
    EXACTLY one lane <-> EXACTLY one process, and it refuses to answer at all when the process map
    itself looks lossy. Two independent reads of the same universe (lsof cwds vs pgrep/ps pids) are
    cross-checked; when they disagree the answer is UNKNOWN, never DEAD.
    """
    files = {}
    for r in rows:
        try:
            files[r["lane"]] = LS.session_file(r.get("sid")) if r.get("sid") else None
        except Exception:
            files[r["lane"]] = None
    try:
        pid_cwds = LS._pi_cwd_map() or {}
    except Exception as e:
        return set(), files, "pid-map unavailable (%s) -- existence UNKNOWN" % type(e).__name__
    if not pid_cwds:
        return set(), files, ("pid-map EMPTY -- existence UNKNOWN for every lane "
                              "(absence of a signal is not evidence of death)")
    dirl, dirp = {}, {}
    for lane, p in files.items():
        if p:
            dirl.setdefault(os.path.basename(os.path.dirname(p)), []).append(lane)
    for pid, cwd in pid_cwds.items():
        try:
            dirl_key = "--" + cwd.strip("/").replace("/", "-") + "--"
        except Exception:
            continue
        dirp.setdefault(dirl_key, []).append(pid)
    cand = []
    for r in rows:
        lane = r.get("lane")
        p = files.get(lane)
        if not p:
            continue
        # Two guards before a lane may be called DEAD, because a false DEAD prescribes a RELAUNCH
        # that replaces the pane command:
        #  * a non-None `cpu` read PROVES a live process for this session dir (lane_cpu_busy only
        #    answers when exactly one lane maps to exactly one pid), so existence is settled and the
        #    map is not consulted. Only unattributable lanes are candidates.
        #  * a transcript written in the last 10 minutes was written by a live process.
        # Both make the verdict strictly weaker than the evidence the tree ranks above it.
        if r.get("cpu") is not None:
            continue
        st = r.get("stale_s")
        if st is not None and st <= 600:
            continue
        d = os.path.basename(os.path.dirname(p))
        if len(dirl.get(d, [])) != 1:
            continue                       # two lanes share this cwd -> unattributable
        if len(dirp.get(d, [])) == 0:
            cand.append(lane)
    if not cand:
        # No lane looks dead, so the SECOND process read -- bought only to detect a LOSSY cwd map --
        # is not needed. It costs ~2s and this check runs inside a bounded heartbeat step.
        return set(), files, ("pid-map %d cwds, every lane attributable to a live pi "
                              "(strict one-lane-one-process)" % len(pid_cwds))
    # A candidate exists, so the answer MATTERS and the lossy-map cross-check must be paid for: two
    # independent reads of the same universe disagreeing means UNKNOWN, never DEAD.
    try:
        cpu_map = LS._pi_cpu_map() or {}
    except Exception:
        cpu_map = {}
    if len(cpu_map) and len(pid_cwds) < 0.6 * len(cpu_map):
        return set(), files, ("pid-map LOSSY (%d cwds vs %d live pi) -- existence UNKNOWN"
                              % (len(pid_cwds), len(cpu_map)))
    return set(cand), files, "pid-map %d cwds / %d pi, strict one-lane-one-process" % (
        len(pid_cwds), len(cpu_map))


# ── the decision tree, in order ───────────────────────────────────────────────────────────
def child_evidence(row):
    """(evidence_strings, live_bool) for a child in flight.

    A `task` child persists NO session file, so the ONLY facts about it are: its own transcript (if
    one was found), its on-disk effect, and the pane line. None of them is decisive; together they
    answer "is the child demonstrably moving".
    """
    ev, live = [], False
    c = row.get("child") or {}
    if c:
        ev.append("child dispatched %s ago" % _age(c.get("age")))
        # A child the CURRENT scan can see, dispatched inside the harness in-flight bound, IS
        # evidence of life -- the record itself is the observation. Without this line the branch
        # below reads "no evidence of life on any signal" for a child that started 40s ago and
        # marks it CHILD-OVERDUE. MEASURED 2026-10-05 on `tortoise-sweep`.
        if c.get("age") is not None and c["age"] < OVERDUE_S:
            live = True
    if row.get("child_grew"):
        ev.append("child transcript grew in the sample window")
        live = True
    cs = row.get("child_stale")
    if cs is not None:
        if cs <= 900:
            ev.append("child wrote %s ago" % _age(cs))
            live = True
        else:
            ev.append("child transcript quiet %s" % _age(cs))
    ca = row.get("child_activity")
    if ca is not None:
        if ca <= 900:
            ev.append("child wrote a file %s ago" % _age(ca))
            live = True
        else:
            ev.append("child file activity stale %s" % _age(ca))
    pk = row.get("pane_children") or []
    if pk:
        youngest = min((k.get("age") or 0) for k in pk)
        ev.append("pane shows %d child session(s), youngest %s old" % (len(pk), _age(youngest)))
        if youngest < PANE_CHILD_LIVE_S:
            live = True
    dec = row.get("declared") or []
    if dec:
        ev.append("%d declared pi child process(es) alive" % len(dec))
        live = True
    return ev, live


def dispatch_result(parent_file, LS):
    """Did this lane's newest `task`/`subagent` dispatch RETURN?

    True = returned (a `toolResult` for its call id is recorded in the lane's OWN transcript),
    False = still open (no result recorded), None = cannot tell.

    WHY THIS EXISTS. A dispatch that RETURNED and a dispatch that was CUT are INDISTINGUISHABLE
    by the "is there a child transcript to recurse into" test: neither leaves a child behind, so
    both read as "no child". They have OPPOSITE actions -- a cut child needs intervention, a
    returned one means the lane has moved on. The difference is not in the child, it is in the
    PARENT: a returned dispatch HAS a toolResult, keyed by its call id. `lane-status.py` already
    pairs calls to results for its own purposes; this reuses that pairing rather than writing a
    new one, and it is asked here only of the dispatch the classifier believes is unmatched.
    """
    if not parent_file or LS is None:
        return None
    try:
        calls, results = {}, set()
        for rec in LS.records(parent_file):
            m = rec.get("message") or {}
            if m.get("role") == "assistant":
                for c in (m.get("content") or []):
                    if isinstance(c, dict) and c.get("type") in ("toolCall", "tool_use") \
                            and c.get("name") in ("task", "subagent"):
                        calls[c.get("id")] = rec.get("timestamp") or ""
            elif m.get("role") == "toolResult":
                results.add(m.get("toolCallId"))
        if not calls:
            return None
        newest_id = max(calls.items(), key=lambda kv: kv[1])[0]
        return newest_id in results
    except Exception:
        return None


def classify_row(row, dead, files, LS):
    """Return a dict: step, verdict, why, action_class. Deterministic; no Jev here."""
    lane = row["lane"]
    sid = row.get("sid")
    r = {"lane": lane, "ws": row.get("ws") or "", "stale": row.get("stale_s"),
         "verdict": None, "step": None, "why": [], "action": None}

    # -- STEP 0 identity ----------------------------------------------------------------
    if not sid:
        r.update(verdict="UNBOUND", step="0", action="report")
        r["why"].append("the pane advertises no session binding, so nothing below can be "
                        "attributed to this lane (NEVER dead, NEVER idle)")
        return r
    if row.get("_dup_sid"):
        r.update(verdict="AMBIGUOUS-IDENT", step="0", action="report")
        r["why"].append("session %s is claimed by %s -- neither panel's staleness or CPU reading "
                        "is demonstrably about this lane" % (sid[:8], ", ".join(row["_dup_sid"])))
        return r

    # -- STEP 1 does the process exist? -------------------------------------------------
    if lane in dead:
        r.update(verdict="DEAD", step="1", action="wedged")
        r["why"].append("no live pi process for this lane's session dir (strict one-lane-one-process "
                        "attribution; transcript last written %s ago)" % _age(row.get("stale_s")))
        return r

    # -- STEP 2 CPU-TIME DELTA (the strongest signal; cumulative `ps -o time`, not `pcpu`) --
    if row.get("cpu") is True:
        r.update(verdict="WORKING", step="2", action=None)
        r["why"].append("cumulative CPU time advanced by more than the stated %.2fs tolerance over "
                        "the sample window" % TOL_CPU_S)
        return r
    if row.get("grew") is True:
        r.update(verdict="WORKING", step="2", action=None)
        r["why"].append("its transcript grew during the sample window")
        return r

    # -- STEP 3 is a child in flight? ---------------------------------------------------
    # An unmatched `task`/`subagent` tool call IS a child dispatch: it lives in THIS lane's own
    # transcript (so it is ATTRIBUTABLE -- unlike a cwd-guessed pid), and the harness's in-flight
    # bound applies to it. lane-status.py's `child` field only carries a child when a child SESSION
    # FILE was found, and past its own 30m ABANDON_S it drops the record as stale -- correct for a
    # file probe, WRONG for a dispatcher, because an unmatched dispatch is exactly the CHILD-OVERDUE
    # case the tree's Step 6 exists for.
    # MEASURED 2026-10-05: `4a Retrieval and traversal` dispatched `subagent([VGATE] verify files)`
    # 2h50m earlier and never got a result, while its last words (4h10m old) said the work was DONE
    # -- so the words layer returned DONE_READY(0.55) and would have re-tasked a lane stuck on a cut
    # child. This is the trap the tree names ("a lane inside a long tool call has a stale last
    # turn"); deterministic code settles it, and Jev never sees the question.
    disp = row.get("tool") or {}
    if disp.get("name") in ("task", "subagent"):
        age = disp.get("age") or 0
        tmo = disp.get("timeout")
        if not (tmo and age < tmo):
            if age > OVERDUE_S:
                # ⛔ Before calling this OVERDUE, disambiguate the two states that look identical
                # from a missing child: RETURNED vs UNMATCHED. Both leave no child transcript, so
                # the child test alone cannot tell them apart, and their actions are opposite.
                returned = dispatch_result(files.get(lane), LS)
                if returned is True:
                    # It RETURNED. Not overdue, not cut. Fall through to the rest of the tree
                    # (Step 3 child / Step 4 tool age / Step 5 words) on the lane's OWN evidence.
                    r["why"].append(
                        "the %s dispatch %s old RETURNED -- its `toolResult` is recorded in this "
                        "lane's own transcript, so it is NOT overdue and NOT cut; a returned "
                        "dispatch leaves no child behind either, which is why the child test "
                        "cannot see the difference" % (disp.get("name"), _age(age)))
                    row = dict(row)
                    row["tool"] = None      # do not re-read the settled dispatch in Step 4/5
                else:
                    # STEP 6 RECURSION: the child, not the parent, decides whether quiet is
                    # correct. A child past the bound is frequently legitimate, and the parent's
                    # quiet is then CORRECT rather than a wedge.
                    ev, child_live = child_evidence(row)
                    if child_live:
                        r.update(verdict="WAITING_ON_CHILD", step="3", action=None)
                        r["why"].append(
                            "%s dispatch %s old, past the %dm bound, but a child IS demonstrably "
                            "in flight -- the parent's quiet is CORRECT, not a wedge"
                            % (disp.get("name"), _age(age), OVERDUE_S // 60))
                        r["why"] += ev
                        return r
                    r.update(verdict="CHILD-OVERDUE", step="6", action="wedged")
                    r["why"].append(
                        "an UNMATCHED %s dispatch is %s old, past the %dm harness in-flight "
                        "bound: no result is recorded for its call id and no child is reachable "
                        "to recurse into. We know the dispatch is UNMATCHED -- we do NOT know it "
                        "was cut; nothing readable from here can see a cut"
                        % (disp.get("name"), _age(age), OVERDUE_S // 60))
                    if ev:
                        r["why"] += ev
                    else:
                        r["why"].append(
                            "no child signal is readable from here (no pane child line, no child "
                            "session file, no declared process) -- reporting the THIRD possibility "
                            "is not open to us: a returned dispatch would have shown a result")
                    return r
            else:
                r.update(verdict="WAITING_ON_CHILD", step="3", action=None)
                r["why"].append("%s dispatch in flight %s, inside the %dm harness bound -- quiet "
                                "here is CORRECT"
                                % (disp.get("name"), _age(age), OVERDUE_S // 60))
                return r

    ev, child_live = child_evidence(row)
    has_child = bool(row.get("child") or row.get("declared") or row.get("pane_children"))
    if has_child:
        overdue = (row.get("verdict") in ("CHILD-OVERDUE", "CHILD-STUCK")) or not child_live
        if child_live:
            r.update(verdict="WAITING_ON_CHILD", step="3", action=None)
            r["why"] += ev
            return r
        if row.get("verdict") in ("WAITING-CHILD", "CHILD-OVERDUE", "CHILD-STUCK"):
            # STEP 6: recursion. The parent's quiet is CORRECT only while the child is alive;
            # with no evidence of life it is a real candidate -- but a child past the ~20m bound is
            # FREQUENTLY legitimate (measured: a 119m merge rail, a 35-65m deploy). So it is
            # reported to unblock, never reaped.
            r.update(verdict=("CHILD-OVERDUE" if not child_live else "WAITING_ON_CHILD"),
                     step="6", action="wedged" if not child_live else None)
            r["why"] += ev or ["a child is in flight but nothing about it can be read from here"]
            # THE ROW'S VERDICT IS A SUSPICION, AND THE EVIDENCE JUST PRINTED CAN CONTRADICT IT.
            # MEASURED 2026-10-05: `tortoise-sweep` carried verdict CHILD-OVERDUE from the scan
            # while every readable child signal was 40s old. Repeating "past the 25m bound" as a
            # fact next to "child dispatched 40s ago" gives an unblocker two flat contradictions
            # and no way to choose -- so when the readable signal sits INSIDE the bound, say that it
            # is the RECORD that is overdue and mark it for re-measurement instead.
            ages = []
            if (row.get("child") or {}).get("age") is not None:
                ages.append(row["child"]["age"])
            if row.get("child_stale") is not None:
                ages.append(row["child_stale"])
            for k in (row.get("pane_children") or []):
                if k.get("age") is not None:
                    ages.append(k["age"])
            youngest = min(ages) if ages else None
            if youngest is not None and youngest < OVERDUE_S:
                r["why"].append(
                    "lane-status recorded %s at scan time, but the youngest child signal readable "
                    "from here is %s old -- inside the %dm bound. The RECORD is what is overdue, "
                    "not the child: re-measure before unblocking."
                    % (row.get("verdict"), _age(youngest), OVERDUE_S // 60))
            else:
                r["why"].append("child past the %dm harness bound with no evidence of life on any "
                                "signal -- a long merge rail or deploy looks identical from here"
                                % (OVERDUE_S // 60))
            return r

    # -- STEP 4 how recent was the last tool call? --------------------------------------
    tool = row.get("tool") or {}
    if tool:
        age = tool.get("age")
        tmo = tool.get("timeout")
        if age is not None and tmo and age < tmo:
            r.update(verdict="TOOL-IN-FLIGHT", step="4", action=None)
            r["why"].append("%s in flight %s, inside its OWN declared budget of %ss"
                            % (tool.get("name"), _age(age), tmo))
            return r
        if age is not None and age < COLD_MIN:
            r.update(verdict="TOOL-IN-FLIGHT", step="4", action=None)
            r["why"].append("%s in flight %s (< %dm) -- provisional WORKING, re-check next tick"
                            % (tool.get("name"), _age(age), COLD_MIN // 60))
            return r

    stale = row.get("stale_s")
    if stale is not None and stale < COLD_MIN:
        r.update(verdict="TOOL-IN-FLIGHT", step="4", action=None)
        r["why"].append("last output %s ago (< %dm)" % (_age(stale), COLD_MIN // 60))
        return r

    # -- STEP 5 the only step that yields meaning: read what it actually said -----------
    r.update(verdict="STEP5", step="5", action="words")
    if tool:
        r["why"].append("%s in flight %s with no declared budget" % (tool.get("name"), _age(tool.get("age"))))
    if row.get("verdict") in ("DONE-IDLE", "WIP-IDLE"):
        r["why"].append("no session write for %s, no spinner contradiction" % _age(stale))
    elif row.get("verdict") == "WEDGED":
        r["why"].append("no session write for %s with a spinner on screen -- two flat samples "
                        "cannot distinguish a wedge from a long tool call, so its words decide"
                        % _age(stale))
    else:
        r["why"].append("mechanical verdict %s at %s quiet" % (row.get("verdict"), _age(stale)))
    return r


# ── STEP 5: ONE batched Jev call for the whole fleet's words layer ────────────────────────
STEP5_OUTCOMES = ("CONTINUE", "BLOCKED_EXTERNAL", "BLOCKED_HUMAN", "DONE_READY", "STALLED",
                  "CONTEXT-MISBELIEF")

CONTEXT_CRITERION = (
    "Its last words say it is running out of context / must stop / must hand off to preserve room. "
    "THIS IS NOT A STATE AND THE BELIEF IS FALSE: this harness AUTO-COMPACTS, so context is not a "
    "reason to stop and stopping throws away work for nothing. Choose this only for that belief; "
    "the action is to tell it plainly to CONTINUE the task in hand, NOT to give it a handoff brief "
    "and NOT to treat it as done."
)

STEP5_INSTRUCTIONS = (
    "This state describes ONE coding-agent lane that is QUIET RIGHT NOW: it is not consuming CPU "
    "time, it has no live child in flight, and its last output is older than two minutes. Read its "
    "own last words and decide ONE outcome. The single most important distinction is that IDLE IS "
    "NOT ONE STATE: a lane whose last words name a next step is CONTINUE (mid-task -- it must be "
    "told to continue, NOT given a new task, and NOT counted as capacity); one waiting on CI / the "
    "merge rail / a queue / another lane's PR is BLOCKED_EXTERNAL (report only); one that cannot "
    "advance without a decision only the OWNER can make is BLOCKED_HUMAN (route it to the owner -- "
    "repeating the work will not help); and one that reported a finished result with nothing held "
    "is DONE_READY (hand it the next item for its lane). Reserve STALLED for a lane whose words "
    "name no next step, await nothing external, and report no finished result. The last words are "
    "the strongest evidence available; a spinner or a quiet transcript is not."
)


def jev_step5(rows, LV, enabled=True):
    """(answers {lane: (choice, conf)}, meta). One call, one `choice` question per lane."""
    meta = {"source": "JEV", "model": None, "usage": None, "error": None, "asked": len(rows)}
    if not rows:
        return {}, dict(meta, source="none")
    if not enabled:
        return {}, dict(meta, source="OFF", error="--no-jev")
    if LV is None:
        return {}, dict(meta, source="RULE", error="lane-verdict.py not importable (no key loader)")
    key = None
    try:
        key = LV.jev_key()
    except Exception:
        key = None
    if not key:
        # The key lives in the Jev config file or JEV_API_KEY. Never printed, never logged.
        return {}, dict(meta, source="RULE", error="no Jev key (env JEV_API_KEY / state/jev-config.json)")

    base = dict(getattr(LV, "CRITERIA", None) or {})
    criteria = {}
    for k in STEP5_OUTCOMES:
        criteria[k] = base.get(k) or CONTEXT_CRITERION
    criteria["CONTEXT-MISBELIEF"] = CONTEXT_CRITERION

    state = ["FLEET WORDS LAYER -- %d lane(s) reached Step 5 of the decision tree." % len(rows),
             "Each lane below is NOT consuming CPU, has NO live child, and is past 2 minutes quiet.",
             ""]
    questions = {}
    for i, r in enumerate(rows):
        qk = "lane_%02d" % i
        lm = r.get("last_message") or "(no assistant text found in the bounded window)"
        said = ("said %s ago" % _age(r.get("said_age"))) if r.get("said_age") is not None \
            else "age unknown"
        state += ["LANE %r" % r["lane"],
                  "  quiet_for=%s  spinner=%s  in_flight_tool=%s"
                  % (_age(r.get("stale")), r.get("spinner"), r.get("tool_desc") or "none"),
                  "  LAST_WORDS (%s): %s" % (said, _clip(lm, 600)),
                  ""]
        questions[qk] = {
            "type": "choice",
            "instructions": "Judge LANE %r specifically. %s" % (r["lane"], STEP5_INSTRUCTIONS),
            "criteria": criteria,
        }
    req = urllib.request.Request(
        LV.JEV_URL,
        data=json.dumps({"model": LV.JEV_MODEL, "state": "\n".join(state),
                         "questions": questions}).encode(),
        headers={"Authorization": "Bearer %s" % key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            d = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {}, dict(meta, source="RULE", error="jev http %s: %s"
                        % (e.code, e.read().decode()[:200]))
    except Exception as e:                                            # noqa: BLE001
        return {}, dict(meta, source="RULE", error="jev call failed: %s" % e)
    answers = d.get("answers") or {}
    out = {}
    for i, r in enumerate(rows):
        a = answers.get("lane_%02d" % i) or {}
        if a.get("type") == "choice" and a.get("choice") in STEP5_OUTCOMES:
            out[r["lane"]] = (a["choice"], a.get("confidence"))
    meta["model"] = d.get("model")
    meta["usage"] = d.get("usage")
    meta["answered"] = len(out)
    if len(out) < len(rows):
        meta["error"] = "jev answered %d of %d" % (len(out), len(rows))
    return out, meta


# ── assembly ─────────────────────────────────────────────────────────────────────────────
def _wide_last_text(path, LS, ref, budget_bytes=2_000_000, max_lines=6000):
    """Last assistant text in a wider bounded window, when the 300KB tail held none.

    MEASURED 2026-10-05: `5&9 MCP and SDK surface` had been tool-calling long enough that its last
    300KB of transcript (44 records) contained NO assistant text at all -- so the lane's words, the
    only thing that can explain it, were outside the window. The widened read is still bounded (2MB
    and 6000 lines) and still uses lane-status.py DESCRIBE to parse a record, so there is one
    parser. Reached only for a lane whose narrow window came back empty.
    """
    try:
        sz = os.path.getsize(path)
        with open(path, "rb") as fh:
            fh.seek(max(0, sz - budget_bytes))
            chunk = fh.read().decode("utf-8", "ignore")
    except OSError:
        return "", None
    n = 0
    for line in reversed([l for l in chunk.split("\n") if l.strip()]):
        n += 1
        if n > max_lines:
            break
        try:
            rec = json.loads(line)
        except Exception:
            continue
        m = rec.get("message") or {}
        if m.get("role") != "assistant":
            continue
        kind, txt = LS.describe(rec)
        if kind == "assistant" and txt:
            age = None
            try:
                e = LS.ts_epoch(rec.get("timestamp") or "")
                age = int(ref - e) if e else None
            except Exception:
                age = None
            return _clip(txt, LAST_MSG_CHARS), age
    return "", None


def _last_message(lane, files, LS, ref):
    """(last assistant TEXT, its age in seconds).

    The tree's Step 5 reads "the lane's last assistant message AND its last tool call". They are two
    different records, and the window has to be wide enough to find the first: MEASURED 2026-10-05,
    three lanes (`1 Capture write doors`, `5&9 MCP and SDK surface`, `4a Retrieval and traversal`)
    had SIXTEEN consecutive records with no assistant text at all -- a pure tool loop -- so a
    16-record window reported "no message" for lanes whose last words were the only thing that
    explained them. The read stays bounded (lane-status.tail caps the file window at 300KB) and the
    age is returned WITH the text so a stale last turn cannot be mistaken for current intent.
    """
    p = files.get(lane)
    if p and LS is not None:
        try:
            for rec in reversed(LS.tail(p, 200)):
                m = rec.get("message") or {}
                if m.get("role") != "assistant":
                    continue
                kind, txt = LS.describe(rec)
                if kind == "assistant" and txt:
                    age = None
                    try:
                        e = LS.ts_epoch(rec.get("timestamp") or "")
                        age = int(ref - e) if e else None
                    except Exception:
                        age = None
                    return _clip(txt, LAST_MSG_CHARS), age
        except Exception:
            pass
    if p and LS is not None:
        return _wide_last_text(p, LS, ref)          # wider window, same parser
    return "", None


def _tool_desc(row):
    t = row.get("tool") or {}
    if not t:
        return ""
    d = "%s in flight %s" % (t.get("name"), _age(t.get("age")))
    if t.get("timeout"):
        d += " (declared %ss)" % t["timeout"]
    return d


# The ONLY failures that may fail `live_workspaces()` open. Evaluated ONCE, at import, so a
# monkeypatched test double can never change which errors are swallowed -- and so a programming error
# (NameError / AttributeError / TypeError) always PROPAGATES instead of reading as "cmux unreadable".
# The first version of this function caught bare `Exception` and hid exactly that bug: a NameError
# made the live set empty and turned this filter into a silent no-op that looked like it worked.
_SUBPROC_ERRORS = (OSError, ValueError, subprocess.SubprocessError)

# ⛔ cmux MUST BE RESOLVED BY ABSOLUTE PATH. The beat runs under launchd, whose job has no
# `EnvironmentVariables` block, so it inherits the default PATH `/usr/gnu/bin:/usr/local/bin:/bin:
# /usr/bin:.` -- and cmux is NOT on it (it lives in /Applications/cmux.app/Contents/Resources/bin/).
# A bare `subprocess.run(["cmux", ...])` therefore raises FileNotFoundError, which the fail-open
# polarity correctly treats as "cmux unreadable" -- so the whole workspace-existence filter silently
# did NOTHING in production while passing its tests and working in an interactive shell. Measured
# 2026-10-09: the beat kept emitting `IDLE->11 ... NEEDS-OWNER->2c Pack compile` while the same code
# run by hand emitted `IDLE->7`, which is how the bug was caught.
CMUX_CANDIDATES = (
    "/Applications/cmux.app/Contents/Resources/bin/cmux",
    "/usr/local/bin/cmux",
    "/opt/homebrew/bin/cmux",
    os.path.expanduser("~/bin/cmux"),
)


# ⛔ THE BEAT CANNOT QUERY cmux AT ALL. MEASURED 2026-10-09 from a real launchd context:
# `cmux workspace list` exits 1 with EMPTY stdout and
#   "ERROR: Access denied - only processes started inside cmux can connect".
# Only processes started INSIDE cmux (any lane's pi, or the orchestrator) can query it. TWO earlier
# "fixes" of this filter were verified WRONG for exactly this reason: an interactive shell and an
# `env -i` shell BOTH sit inside cmux, so both reported 22 workspaces while the beat saw none.
# The shell you test from cannot tell you what launchd sees.
# THEREFORE the primary source is a PUBLISHED file that any cmux-resident process can write; cmux is
# only a fallback. When BOTH are unavailable the failure is reported LOUDLY, because an inert filter
# that looks like a working one is precisely the hazard this function exists to remove.
LIVE_WS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir,
                            "state", "live-workspaces.txt")
LIVE_WS_MAX_AGE_S = 900   # a published list older than this is not evidence about the live fleet


def cmux_bin():
    """An ABSOLUTE path to cmux, falling back to a PATH lookup only as a last resort."""
    for p in CMUX_CANDIDATES:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return "cmux"


def live_workspaces():
    """{UPPERCASED UUID: current cmux workspace TITLE} for the workspaces that exist now.

    An EMPTY return means the list could not be read, and callers MUST treat empty as "do not
    filter" -- a failed read must never silently drop a live lane.

    \u26d4 THE TITLE IS LOAD-BEARING, NOT DECORATION (2026-10-10, #7957 H4). A workspace UUID
    OUTLIVES the NAME it was created for, so **UUID existence does not prove the lane exists.**
    Measured 2026-10-10: three of the six lanes the beat offered as IDLE had a live UUID under a
    DIFFERENT title -- `land-6260` was `P1 data-loss`, `Merigng PR` was `PR 2`,
    `\u03c0 - land-lane-1` was `5285 Decision`. A caller that only tests membership therefore offers
    dead lanes as work, and a dispatch is spent on a lane that is not there.

    A title of "" means **UNKNOWN** (a legacy UUID-only published list) and callers MUST NOT filter
    on it -- only a KNOWN, DIFFERING title proves the lane is gone.
    """
    # Source 1 -- the PUBLISHED list. Any process INSIDE cmux can write it (the beat cannot query
    # cmux, so it must not depend on cmux being reachable from launchd).
    reasons = []
    try:
        age = time.time() - os.path.getmtime(LIVE_WS_FILE)
        if age <= LIVE_WS_MAX_AGE_S:
            ids = {}
            with open(LIVE_WS_FILE) as fh:
                for line in fh:
                    line = line.rstrip("\n")
                    if not line.strip() or line.lstrip().startswith("#"):
                        continue
                    # New format is `UUID<TAB>title`. A legacy UUID-only line is still accepted but
                    # yields title "" == UNKNOWN, which the filter refuses to act on.
                    if "\t" in line:
                        uid, _, title = line.partition("\t")
                    else:
                        # Legacy line: `UUID` optionally followed by a whitespace-separated title.
                        parts = line.split(None, 1)
                        uid = parts[0] if parts else ""
                        title = parts[1] if len(parts) > 1 else ""
                    uid = uid.strip().upper()
                    if uid:
                        ids[uid] = title.strip()
            if ids:
                return ids
            reasons.append("published list is empty")
        else:
            reasons.append("published list is %dm old (>%dm)"
                           % (age / 60, LIVE_WS_MAX_AGE_S / 60))
    except OSError:
        reasons.append("no published list at %s" % LIVE_WS_FILE)

    # Source 2 -- cmux directly. Works ONLY when this process is inside cmux.
    # ⛔ CATCH ONLY I/O FAILURES. A blanket `except Exception` here silently converted a NameError
    # (subprocess was imported INSIDE main(), so it was undefined at module scope) into "cmux is
    # unreadable" -- and this filter became a silent NO-OP that returned 0 workspaces while looking
    # like it worked. A programming error must raise loudly; only a genuinely unreadable cmux may
    # fail open. The first version of this function had exactly that bug.
    try:
        p = subprocess.run([cmux_bin(), "workspace", "list", "--json", "--id-format", "both"],
                           capture_output=True, text=True, timeout=20)
        if p.returncode != 0 or not (p.stdout or "").strip():
            # ⛔ rc != 0 OR empty stdout is a FAILURE, not "no workspaces". MEASURED 2026-10-09 from a
            # real launchd context: `cmux workspace list` exits 1 with EMPTY stdout and stderr
            # "ERROR: Access denied - only processes started inside cmux can connect". The empty
            # stdout parsed as `{}` -> no workspaces -> `set()`, so this returned WITHOUT RAISING, the
            # `except` below never ran, and the filter silently did NOTHING in the beat while working
            # in every shell started INSIDE cmux. That produced two rounds of false "verified"
            # (an interactive run and an `env -i` run -- neither reproduces launchd's session, so
            # neither could show it). LOUD from now on: an inert filter must never look like a working
            # one, because the whole point of this function is to stop wrong dispatch instructions.
            reasons.append("cmux rc=%s with %d bytes stdout: %r"
                           % (p.returncode, len(p.stdout or ""), (p.stderr or "").strip()[:120]))
            p = None
        if p is None:
            raise OSError("; ".join(reasons))
        d = json.loads(p.stdout)
        ws = d if isinstance(d, list) else d.get("workspaces", [])
        return {(w.get("id") or "").strip().upper(): (w.get("title") or "").strip()
                for w in ws if w.get("id")}
    except _SUBPROC_ERRORS as e:
        sys.stderr.write(
            "live_workspaces: UNREADABLE -- the workspace-existence filter is INERT this run. "
            "Publish %s from a process INSIDE cmux. (%s)\n" % (LIVE_WS_FILE, e))
        return {}


def build(rows, LS, LV, use_jev=True, ref=None, live=None):
    ref = ref or time.time()          # the SNAPSHOT's clock, so ages agree with stale_s and a
                                     # re-run of the same snapshot is byte-identical
    labels = _registry_labels()
    dup = {}
    for r in rows:
        if r.get("sid"):
            dup.setdefault(r["sid"], []).append(r["lane"])
    for r in rows:
        sib = [x for x in dup.get(r.get("sid") or "", []) if x != r["lane"]]
        r["_dup_sid"] = sib

    dead, files, procmap_note = dead_lanes(rows, LS) if LS is not None else (set(), {}, "lane-status.py not importable")
    busy = _busy_sids()

    classified = []
    for r in rows:
        c = classify_row(r, dead, files, LS)
        c["protected"] = any(p in c["lane"] for p in PROTECTED)
        c["busy"] = bool(r.get("sid") and r["sid"] in busy)
        # Messages are read ONLY where they can change an outcome: a lane proven WORKING by CPU
        # time, or waiting on a live child, or inside a declarable tool budget needs no report at
        # all, and reading 30 session tails to print none of them is cost without evidence.
        if c["step"] in ("5", "1", "6"):
            c["last_message"], c["said_age"] = _last_message(c["lane"], files, LS, ref)
        else:
            c["last_message"], c["said_age"] = "", None
        c["spinner"] = bool(r.get("spinner"))
        c["tool_desc"] = _tool_desc(r)
        c["issue_label"] = r.get("issue_label") or ""
        classified.append(c)

    # STEP 5 -- only the lanes that reached it, in ONE batched call. PROTECTED lanes are excluded
    # from the call itself, not just from the lists: they are the OWNER own work (DMeer / DMer /
    # HANG) and their text does not belong in a third-party API request for a fleet triage.
    step5 = [c for c in classified if c["step"] == "5" and not c["protected"]]
    step5.sort(key=lambda c: -(c["stale"] or 0))
    answers, meta = jev_step5(step5, LV, enabled=use_jev)
    jev_down = bool(step5) and not answers and meta.get("source") not in ("none",)
    for c in classified:
        if c["step"] != "5":
            continue
        got = answers.get(c["lane"])
        if got:
            c["verdict"], c["conf"] = got
            c["step"] = "5"
        elif c["protected"]:
            c["verdict"], c["conf"] = "PROTECTED", None
            c["why"].append("owner lane -- its words are not read here (never offered as work)")
        else:
            c["verdict"] = "UNCLASSIFIED"
            c["conf"] = None
            c["why"].append("words layer UNREAD (Jev: %s) -- reported, never guessed into an action"
                            % (meta.get("error") or meta.get("source")))

    # -- buckets. The tree's resolution table, applied verbatim ---------------------------
    idle, wip, wedged, report, quiet = [], [], [], [], []
    OFFERABLE = ("DONE_READY", "CONTINUE", "CONTEXT-MISBELIEF", "STALLED", "DEAD", "CHILD-OVERDUE")
    for c in classified:
        v = c["verdict"]
        # Steps 2-4 resolved the lane to a NO-ACTION verdict (WORKING / WAITING_ON_CHILD /
        # TOOL-IN-FLIGHT). It needs neither an action nor a report, so it appears in neither
        # section -- it is counted in the summary line instead, so the reader can see the whole
        # fleet was classified rather than just the lanes that needed something.
        if c["step"] in ("2", "3", "4") or v == "WORKING":
            quiet.append(c)
            continue
        # PROTECTED covers EVERY verdict, not only the offerable ones: an owner lane is never an
        # action target whatever the classifier thought of it, and the reason must lead the entry so
        # a reader cannot mistake it for capacity.
        if c["protected"]:
            c["why"].insert(0, "PROTECTED lane (owner's own work) -- NEVER offered as work")
            report.append(c)
            continue
        if v in OFFERABLE and c["busy"]:
            c["why"].insert(0, "already auto-nudged this hour (result SENT/QUEUED) -- do NOT "
                               "message again; it is working")
            report.append(c)
            continue
        if v == "DONE_READY":
            idle.append(c)
        elif v == "CONTINUE":
            wip.append(c)
        elif v == "CONTEXT-MISBELIEF":
            c["why"].insert(0, "says it must stop to preserve context -- FALSE: this harness "
                               "auto-compacts. Tell it plainly to CONTINUE the task in hand; it is "
                               "NOT finished and NOT free capacity.")
            wip.append(c)
        elif v in ("STALLED", "DEAD", "CHILD-OVERDUE"):
            wedged.append(c)
        else:                                           # BLOCKED_* / UNBOUND / AMBIGUOUS / UNCLASSIFIED
            report.append(c)

    for b in (idle, wip, wedged, report, quiet):
        b.sort(key=lambda c: (c["lane"].lower(),))
    # `words_read` is what the floor keys on before it lets this clause SUPERSEDE the previous
    # clauses: it is true only when EVERY lane that needed Step 5 actually got an answer. A partial
    # answer (or any Jev error) leaves the older clauses standing, so an outage cannot silently
    # shrink the action set.
    words_read = (not step5) or (meta.get("source") == "JEV" and not meta.get("error")
                                 and meta.get("answered") == meta.get("asked"))
    # ── WORKSPACE-EXISTENCE FILTER ─────────────────────────────────────────────────────────────
    # ⛔ A lane whose cmux workspace no longer exists cannot be dispatched to, unblocked or
    # relaunched, and its recorded "words" are a position from a lane that is GONE -- not a live
    # one. So it must not populate an actionable list, and must NEVER be routed to the owner as a
    # decision. Measured 2026-10-09 (tortoise#7738): five roster rows with no workspace (2c Pack
    # compile, 4a Retrieval and traversal, 6 Durability core, 8 Hosted reliability, land-lane-4) were
    # offered simultaneously as `IDLE->need dispatch`, `WEDGED->unblock` AND `NEEDS-OWNER->route it`.
    # The last is the serious one: it would have carried a DECISION to the owner from a lane that
    # does not exist. They move to REPORT ONLY, which keeps the evidence without acting on it.
    # POLARITY: an unreadable workspace list filters NOTHING -- the same fail-open rule the DEAD
    # classifier uses above, so a cmux hiccup can never hide a real lane.
    # `live` is injectable so the test is DETERMINISTIC: without it every test inherits whatever
    # cmux happens to be running, which is how the first version of this filter passed its own test
    # for the wrong reason. Passing live=set() disables the filter entirely.
    # Normalised to a DICT in every case (uuid -> title). `live=set()` therefore still disables the
    # filter entirely, which is what the tests rely on; `live={uuid: title}` carries real titles.
    if live is None:
        _live = live_workspaces()
    elif isinstance(live, dict):
        _live = {str(k).strip().upper(): str(v) for k, v in live.items()}
    else:
        _live = {str(x).strip().upper(): "" for x in live}
    if _live:
        def _norm(s):
            return " ".join((s or "").split()).casefold()

        def _keep_if_live(bucket):
            out = []
            for c in bucket:
                ws = (c.get("ws") or "").strip().upper()
                title = _live.get(ws, "")
                if ws and ws not in _live:
                    c["why"].insert(0, "cmux workspace %s no longer exists -- not dispatchable, not "
                                        "unblockable, not routeable; its words are a recording from "
                                        "a lane that is gone (workspace-existence filter, #7738)"
                                    % (c.get("ws") or "?"))
                    report.append(c)
                elif title and _norm(title) != _norm(c.get("lane")):
                    # ⛔ THE UUID SURVIVED; THE LANE DID NOT (2026-10-10, #7957 H4). Measured: three of
                    # six lanes offered as IDLE had a live UUID under a different title -- `land-6260`
                    # was `P1 data-loss`, `Merigng PR` was `PR 2`, `\u03c0 - land-lane-1` was
                    # `5285 Decision`. A UUID-existence check passed all three, so the beat spent
                    # dispatches on lanes that had been renamed out from under it. Only a KNOWN,
                    # DIFFERING title demotes -- an unknown title (legacy list) never does, so a
                    # format downgrade can never hide a real lane.
                    c["why"].insert(0, "cmux workspace %s is now titled %r, NOT %r -- this lane no "
                                        "longer exists under that name, so its words are a recording "
                                        "from a lane that is gone (workspace-NAME filter, #7957 H4)"
                                    % (ws or "?", title, c.get("lane") or "?"))
                    report.append(c)
                else:
                    out.append(c)
            return out
        idle, wip, wedged = _keep_if_live(idle), _keep_if_live(wip), _keep_if_live(wedged)

    return {"idle": idle, "wip": wip, "wedged": wedged, "report": report, "quiet": quiet,
            "meta": meta, "jev_down": jev_down, "words_read": bool(words_read),
            "procmap": procmap_note,
            "n_lanes": len(rows), "n_registry": len(labels), "files": files}


# ── the FILE ─────────────────────────────────────────────────────────────────────────────
def render_md(res, snapshot_age, source):
    ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    m = res["meta"]
    words = ("READ (Jev %s: %s of %s lanes answered)"
             % (m.get("model") or "?", m.get("answered"), m.get("asked"))
             if m.get("source") == "JEV" and not m.get("error")
             else "NOT READ (%s)" % (m.get("error") or m.get("source") or "off"))
    L = []
    L.append("# NEEDS-ACTION -- automatic lane classification")
    L.append("")
    L.append("_Generated %s by `scripts/lane-actions.py` from `lane-status.py --json` "
             "(snapshot %ss old, %d lanes). Tree: `state/LANE-STATE-DECISION-TREE.md`._"
             % (ts, snapshot_age, res["n_lanes"]))
    L.append("")
    # A SNAPSHOT OLDER THAN THE TICK'S OWN BOUND IS NORMAL, NOT AN ERROR -- but every age below is
    # measured against the SNAPSHOT, so a reader who does not know its age will read a 12-minute-old
    # verdict as a live one. The tick is bounded at 390s and its scan is the LAST thing it does, so
    # a scan that does not finish inside the bound leaves the PREVIOUS completed scan in place.
    if snapshot_age > 600:
        L.append("> **STALE SNAPSHOT (%s old).** The tick's scan did not complete inside its own "
                 "bound, so this is the last COMPLETED scan. The verdicts, ages and last messages "
                 "below are all measured at that snapshot: re-read a lane before acting on it."
                 % _age(snapshot_age))
        L.append("")
    L.append("- Steps 1-4 (identity, process, **CPU-time delta**, child, tool age): deterministic code.")
    L.append("- Step 5 (read what it said): %s. Jev decides ONLY this layer." % words)
    L.append("- Existence check: %s." % res["procmap"])
    L.append("- No action needed (%d): Steps 2-4 resolved them to WORKING / WAITING_ON_CHILD / "
             "TOOL-IN-FLIGHT -- %s."
             % (len(res["quiet"]), ", ".join("%s[%s]" % (c["lane"], c["verdict"])
                                              for c in res["quiet"]) or "none"))
    L.append("- PROTECTED lanes (%s) and auto-nudged (BUSY) lanes are never offered as work."
             % "/".join(PROTECTED))
    L.append("- Entry format: `- <lane> [<verdict> <confidence>] (<how long since its last output>) "
             "[<cmux-workspace-uuid>] \u2014 <last message>` -- the WHY line below carries every other "
             "age (the words, the child, the tool) so no number here has to be guessed at.")
    L.append("")

    def entry(c):
        return "- %s [%s%s] (%s) [%s] \u2014 %s" % (
            c["lane"], c["verdict"],
            (" %.2f" % c["conf"]) if c.get("conf") is not None else "",
            _age(c["stale"]), (c["ws"] or "?").upper(),
            _clip(c["last_message"], LAST_MSG_CHARS) or "(no assistant text)")

    def whyline(c):
        extra = ""
        if c.get("said_age") is not None:
            extra = "last words said %s ago" % _age(c["said_age"])
        body = " | ".join(c["why"])
        return "    - WHY: " + " | ".join(x for x in (extra, body) if x)

    L.append("## LIST 1 -- IDLE, NEEDS A DISPATCH  (%d)" % len(res["idle"]))
    L.append("")
    L.append("Action: hand each of these the next unheld item for its lane. Its last words said it "
             "finished and holds nothing.")
    L.append("")
    if res["idle"]:
        for c in res["idle"]:
            L.append(entry(c))
            L.append(whyline(c))
    else:
        L.append("(none -- do NOT read that as all-idle; check the REPORT ONLY section)")
    L.append("")

    L.append("## LIST 1b -- MID-TASK, SAY **CONTINUE**  (%d)" % len(res["wip"]))
    L.append("")
    L.append("Action: ONE instruction -- continue. These are mid-task, NOT free capacity, and a new "
             "task here re-tasks work in hand. (Listed separately from LIST 1 because the "
             "instruction is different.)")
    L.append("")
    if res["wip"]:
        for c in res["wip"]:
            L.append(entry(c))
            L.append(whyline(c))
    else:
        L.append("(none)")
    L.append("")

    L.append("## LIST 2 -- WEDGED, TO UNBLOCK  (%d)" % len(res["wedged"]))
    L.append("")
    L.append("Action: investigate and unblock. NOT a reap list -- two flat samples cannot "
             "distinguish a wedge from a long tool call, and a child past 20m is frequently a "
             "legitimate merge rail or deploy.")
    L.append("")
    if res["wedged"]:
        for c in res["wedged"]:
            L.append(entry(c))
            L.append(whyline(c))
    else:
        L.append("(none)")
    L.append("")

    L.append("## REPORT ONLY -- DO NOT ACT  (%d)" % len(res["report"]))
    L.append("")
    L.append("The tree forbids acting on these: a false DONE_READY re-tasks a mid-work lane, and a "
             "false STALLED wakes an expensive session for nothing. Reporting costs nothing.")
    L.append("")
    if res["report"]:
        for c in res["report"]:
            L.append(entry(c))
            L.append(whyline(c))
    else:
        L.append("(none)")
    L.append("")
    return "\n".join(L) + "\n"


# ── the BEAT clause (ONE line, short: names inline, messages in the file) ─────────────────
def render_beat(res, path_for_beat):
    """The beat's clause: NAMES inline (short), MESSAGES in the file.

    HARD CONSTRAINT -- ONE LINE, NO EMBEDDED NEWLINE: `cmux send "$MSG\\n"` submits EACH newline as
    its own turn, which the owner reported as "a mess... massive noise". The other constraint is
    length: the beat is already near its display limit, so every clause here is a COUNT + a few
    names + a pointer, and the rest is in the file.
    """
    note = " [JEV-DOWN: words layer UNREAD -- reported, not guessed]" if res["jev_down"] else ""

    def names(lst):
        got = [c["lane"] for c in lst[:MAX_NAMES]]
        extra = len(lst) - len(got)
        return ", ".join(got) + (" (+%d more)" % extra if extra else "")

    parts = []
    if res["idle"]:
        parts.append("IDLE->%d need dispatch (see %s): %s"
                     % (len(res["idle"]), path_for_beat, names(res["idle"])))
    elif res["wip"]:
        parts.append("WIP->%d say CONTINUE, not a new task (see %s): %s"
                     % (len(res["wip"]), path_for_beat, names(res["wip"])))
    elif res["wedged"]:
        parts.append("WEDGED->%d unblock (see %s): %s"
                     % (len(res["wedged"]), path_for_beat, names(res["wedged"])))
    else:
        parts.append("NOTHING-ACTIONABLE (see %s)" % path_for_beat)
    if res["idle"] and res["wip"]:
        parts.append("WIP->%d say CONTINUE, not a new task: %s"
                     % (len(res["wip"]), names(res["wip"])))
    if (res["idle"] or res["wip"]) and res["wedged"]:
        parts.append("WEDGED->%d unblock: %s" % (len(res["wedged"]), names(res["wedged"])))
    if res["report"]:
        parts.append("REPORT-ONLY->%d (do NOT act)" % len(res["report"]))
    line = " ".join((" | ".join(parts) + note).split())
    return line if len(line) <= SUMMARY_MAX else line[:SUMMARY_MAX - 1].rstrip() + "\u2026"


# ── input ────────────────────────────────────────────────────────────────────────────────
def load_snapshot(args):
    """(rows, snapshot_age_s, reference_clock). Rejects a PARTIAL snapshot -- see the note below."""
    if args.stdin:
        try:
            if args.stdin == "-":
                raw, ref = sys.stdin.read(), time.time()
            else:
                raw = open(args.stdin, errors="ignore").read()
                try:
                    ref = os.path.getmtime(args.stdin)
                except OSError:
                    ref = time.time()
            rows = json.loads(raw)
        except Exception as e:
            raise SystemExit("lane-actions: cannot read snapshot %s: %r" % (args.stdin, e))
        # The header must state the DATA's age, not the run time: a snapshot published by an earlier
        # pass (a killed tick leaves the last good one in place) is still usable, but the reader has
        # to be able to see how old it is.
        age = int(max(0, time.time() - ref)) if args.stdin != "-" else 0
        return rows, age, ref
    # Invoke lane-status.py. Its cache is ONE file keyed by --only, so a caller that scanned a
    # SUBSET (queue-dispatch's two-read guard does exactly this) OVERWRITES the fleet-wide snapshot
    # and every later consumer in the same pass silently reads 4 lanes instead of 30. Detected and
    # refused here: a partial snapshot is re-scanned for real rather than classified as the fleet.
    sys.path.insert(0, SCRIPTS)
    import subprocess
    want = len(_registry_labels())
    for attempt in (0, 1):
        cmd = ["/usr/bin/python3", LS_PATH, "--json", "--sample", str(args.sample)]
        if attempt:
            cmd.append("--no-cache")
        try:
            raw = subprocess.run(cmd, capture_output=True, text=True, timeout=args.budget).stdout
            rows = json.loads(raw)
        except Exception as e:
            raise SystemExit("lane-actions: lane-status.py failed: %r" % (e,))
        try:
            age = int(time.time() - os.path.getmtime(
                os.path.join(STATE, "lane-status.cache")))
        except OSError:
            age = 0
        if not want or len(rows) >= want - REGISTRY_GRACE:
            try:
                ref = os.path.getmtime(os.path.join(STATE, "lane-status.cache"))
            except OSError:
                ref = time.time()
            return rows, age, ref
        sys.stderr.write("lane-actions: snapshot PARTIAL (%d of %d registry lanes) -- "
                         "re-scanning without the cache\n" % (len(rows), want))
    return rows, age, time.time()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stdin", metavar="FILE", default=None,
                    help="read the lane-status JSON from FILE ('-' = stdin) instead of invoking it")
    ap.add_argument("--out", default=OUT_PATH)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-jev", action="store_true", help="deterministic only; words layer UNREAD")
    ap.add_argument("--sample", type=float, default=12.0)
    ap.add_argument("--budget", type=float, default=300.0,
                    help="bound for the lane-status invocation when this file invokes it")
    a = ap.parse_args()

    LS = _load(LS_PATH, "lane_status")
    LV = _load(LV_PATH, "lane_verdict")
    rows, snap_age, ref = load_snapshot(a)
    if not isinstance(rows, list) or not rows:
        sys.stderr.write("lane-actions: empty snapshot -- refusing to write a verdict\n")
        return 2

    res = build(rows, LS, LV, use_jev=not a.no_jev, ref=ref)
    md = render_md(res, snap_age, "lane-status.py")
    try:
        tmp = a.out + ".tmp"
        with open(tmp, "w") as fh:
            fh.write(md)
        os.replace(tmp, a.out)                 # atomic: a reader never sees a half-written file
    except OSError as e:
        sys.stderr.write("lane-actions: cannot write %s: %s\n" % (a.out, e))
        return 3
    beat = render_beat(res, display_path(a.out))
    # The tick reads this sidecar rather than parsing stdout: the beat clause is ONE line with no
    # quoting hazards, and `actfull` is what lets the floor know whether the classifier words layer
    # was actually read -- so a Jev outage degrades to the previous beat instead of publishing an
    # empty action list as if the fleet were clean.
    try:
        tmp = BEAT_PATH + ".tmp"
        with open(tmp, "w") as fh:
            fh.write("act=%s\nactfull=%d\n" % (beat.replace("\n", " "),
                                                1 if res["words_read"] else 0))
        os.replace(tmp, BEAT_PATH)
    except OSError as e:
        sys.stderr.write("lane-actions: cannot write %s: %s\n" % (BEAT_PATH, e))
    if a.json:
        print(json.dumps({
            "beat": beat, "jev": res["meta"], "jev_down": res["jev_down"],
            "words_read": res["words_read"],
            "counts": {k: len(res[k]) for k in ("idle", "wip", "wedged", "report", "quiet")},
            "idle": res["idle"], "wip": res["wip"], "wedged": res["wedged"],
            "report": res["report"], "quiet": res["quiet"],
        }, indent=1))
    else:
        print(beat)
    return 0


if __name__ == "__main__":
    sys.exit(main())
