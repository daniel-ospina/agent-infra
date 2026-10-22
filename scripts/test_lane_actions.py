#!/usr/bin/env python3
"""test_lane_actions.py -- the DETERMINISTIC layer of scripts/lane-actions.py, pinned by test.

WHY: the deliverable is "an automatic process" that decides which lanes to dispatch and which to
unblock. Its value is that it is REPEATABLE and WRONG IN KNOWN DIRECTIONS, so the step ordering that
produces those directions has to be pinned by a test rather than by a comment. The Jev layer (Step
5) is not called here: it is not deterministic, and it is asserted only through its FAILURE DIRECTION
(the words layer unread must land in REPORT ONLY, never in an action list).

Run: /usr/bin/python3 scripts/test_lane_actions.py
"""
import importlib.util
import atexit
import hashlib
import json
import os
import shutil
import tempfile

# The scratch directory the module this file loads persists into (#1734). Module-level because it
# must outlive any single class: `_objective_mod()` mints a fresh module object per call.
_STATE_SCRATCH = tempfile.mkdtemp(prefix="lane-actions-state-")
atexit.register(shutil.rmtree, _STATE_SCRATCH, ignore_errors=True)
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = os.path.dirname(HERE)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


LA = load("lane_actions", os.path.join(HERE, "lane-actions.py"))
# The REAL lane-status module, so `FakeLS` delegates the shared rule to it instead of restating it --
# a fake that reimplements the rule under test cannot detect that rule changing.
LS_MOD = load("lane_status", os.path.join(HERE, "lane-status.py"))

FAILS = []


def check(name, cond, detail=""):
    if cond:
        print("  ok   %s" % name)
    else:
        print("  FAIL %s %s" % (name, detail))
        FAILS.append(name)


class FakeLS:
    """The minimum of lane-status.py that lane-actions.py actually calls."""

    def __init__(self, files=None, cwds=None, cpus=None, recs=None):
        self._files = files or {}
        self._cwds = cwds or {}
        self._cpus = cpus if cpus is not None else dict(self._cwds)
        self._recs = recs or []

    def session_file(self, sid):
        return self._files.get(sid)

    def _pi_cwd_map(self):
        return self._cwds

    def _pi_cpu_map(self):
        return self._cpus

    def tail(self, path, want=8):
        return []

    def describe(self, rec):
        return ("assistant", "")

    def ts_epoch(self, ts):
        return 0

    def told_but_silent(self, inbound_age, stale_s):
        return LS_MOD.told_but_silent(inbound_age, stale_s)

    def records(self, path, limit=None):
        return self._recs


# ⛔ ONE REAL FLEET ROOT FOR EVERY FIXTURE, CREATED ONCE AND PORTABLE (review round 4, P2/P3).
# `wt-<slug>` is no longer accepted on its NAME: it must be a real linked git worktree inside a fleet
# root (`_is_linked_worktree` reads the `.git` FILE `git worktree add` writes). So the fixtures build
# the artifact instead of citing a path that happens to exist on the box -- the previous version cited
# `/tmp/wt-9204/scripts` and was green only because that path is a symlink on ONE machine.
_FLEET_WT_ROOT = tempfile.mkdtemp(prefix="lane-fleet-root-")
atexit.register(shutil.rmtree, _FLEET_WT_ROOT, ignore_errors=True)
LA.FLEET_ROOTS = tuple(LA.FLEET_ROOTS) + (_FLEET_WT_ROOT,)


def fleet_wt(lane, n=None):
    """`<fixture fleet root>/wt-<n>`, created on disk AND as a real linked worktree (`.git` file)."""
    n = n if n is not None else (abs(sum(ord(ch) for ch in lane)) % 9000 + 100)
    d = os.path.join(_FLEET_WT_ROOT, "wt-%d" % n)
    if not os.path.isdir(d):
        os.makedirs(d)
        with open(os.path.join(d, ".git"), "w") as fh:
            fh.write("gitdir: %s/.git/worktrees/wt-%d\n" % (_FLEET_WT_ROOT, n))
    return d


def fleet_cwd(lane, n=None):
    """The cwd of a REAL fleet lane: a worktree, never the owner's project.

    ⛔ THE FIXTURES MUST MODEL THE EVIDENCE, NOT ASSUME IT. Before identity became evidence-based
    (owner, 2026-10-20) a fixture could put a lane anywhere and still be dispatchable, because
    "fleet lane" meant "appears in the roster". It now means "its session cwd is demonstrably a
    fleet worktree", so a fixture with `/x/repo-<lane>` is -- correctly -- PROTECTED, and a test
    that expects it to be offered would be asserting the OLD rule. These helpers keep every bucket
    test honest: a lane is given the shape a lane actually has on this box.

    The number is derived from the lane name so it is stable across runs (`hash()` is salted). It is
    derived so `fleet_cwd(x) == fleet_cwd(x)` holds, and `fleet_session()` keeps encoding the same
    path -- both fixtures read it.
    """
    return fleet_wt(lane, n)


def fleet_session(lane, n=None):
    """A session file whose DIRECTORY is lane-status's mangling of `fleet_cwd(lane)`.

    The directory name is the same evidence the dead-lane attribution reads, so one fixture feeds
    both: `--<fixture-fleet-root>-wt-<n>--` <-> `<fixture fleet root>/wt-<n>`.
    """
    return os.path.join(AGENT, "state", "sessions",
                        "--" + fleet_cwd(lane, n).strip("/").replace("/", "-") + "--",
                        "s.jsonl")


def rec_call(cid, name="subagent", ts="2026-10-05T10:00:00.000Z"):
    """One `task`/`subagent` toolCall, in the shape a session transcript stores it."""
    return {"timestamp": ts, "message": {"role": "assistant", "content": [
        {"type": "toolCall", "name": name, "id": cid}]}}


def rec_result(cid, name="subagent", ts="2026-10-05T10:30:00.000Z"):
    """The matching toolResult -- what a RETURNED dispatch leaves behind."""
    return {"timestamp": ts, "message": {"role": "toolResult", "toolName": name,
                                            "toolCallId": cid, "content": []}}


def row(**kw):
    r = dict(lane="L", verdict="DONE-IDLE", stale_s=1200, grew=False, cpu=None, declared=[],
             pane_children=[], spinner=False, sid="sid-1", ws="WS-1", size=1,
             issue_label="", last="assistant", recent=[], child=None, child_file=None,
             child_stale=None, child_grew=None, child_activity=None, tool=None)
    r.update(kw)
    return r


def cls(r, dead=(), LS=None):
    LS = LS or FakeLS()
    files = {}
    try:
        files[r["lane"]] = LS.session_file(r.get("sid"))
    except Exception:
        pass
    r["_dup_sid"] = []
    return LA.classify_row(r, set(dead), files, LS)


def main():
    print("Step 2 -- CPU-time delta is the strongest signal and short-circuits")
    c = cls(row(cpu=True))
    check("cpu True -> WORKING", c["verdict"] == "WORKING" and c["step"] == "2", c)
    check("cpu True -> no action", c["action"] is None)
    check("cpu True -> no Jev", c["action"] is None)
    c = cls(row(grew=True, stale_s=3))
    check("transcript grew -> WORKING", c["verdict"] == "WORKING" and c["step"] == "2", c)

    print("Step 0 -- identity, and it can never be idle or dead")
    c = cls(row(sid=None))
    check("no session binding -> UNBOUND", c["verdict"] == "UNBOUND", c)
    check("UNBOUND -> report only", c["action"] == "report", c)
    r = row()
    r["_dup_sid"] = ["sibling"]
    c = LA.classify_row(r, set(), {}, FakeLS())
    check("shared session id -> AMBIGUOUS-IDENT", c["verdict"] == "AMBIGUOUS-IDENT", c)
    check("AMBIGUOUS-IDENT -> report only", c["action"] == "report", c)

    print("Step 1 -- existence, strict attribution or UNKNOWN")
    p = os.path.join(AGENT, "state", "sessions", "--Users-me-repo--", "s.jsonl")
    fs = FakeLS(files={"sid-1": p}, cwds={"99": "/somewhere/else"})
    dead, _files, note = LA.dead_lanes([row()], fs)
    check("no process for this session dir -> DEAD", dead == {"L"}, (dead, note))
    c = cls(row(), dead=dead, LS=fs)
    check("DEAD -> unblock list", c["verdict"] == "DEAD" and c["action"] == "wedged", c)
    # same lane, but another lane shares the dir -> unattributable -> NOT dead
    fs2 = FakeLS(files={"sid-1": p, "sid-2": p}, cwds={"99": "/somewhere/else"})
    dead2, _f, _n = LA.dead_lanes([row(), row(lane="L2")], fs2)
    check("two lanes on one cwd -> NOT DEAD (unattributable)", not dead2, dead2)
    # an empty process map is not evidence of death
    dead3, _f, note3 = LA.dead_lanes([row()], FakeLS(files={"sid-1": p}, cwds={}))
    check("empty pid map -> NOT DEAD", not dead3 and "EMPTY" in note3, note3)
    # a LOSSY map (cwds far fewer than live pids) is UNKNOWN, never DEAD
    dead4, _f, note4 = LA.dead_lanes(
        [row()], FakeLS(files={"sid-1": p}, cwds={"1": "/x"},
                        cpus=dict((str(i), 1) for i in range(10))))
    check("lossy pid map -> NOT DEAD", not dead4 and "LOSSY" in note4, note4)

    print("Step 3 -- a child in flight")
    c = cls(row(verdict="WAITING-CHILD", child={"age": 600, "task": "x"}, child_grew=True))
    check("live child -> WAITING_ON_CHILD", c["verdict"] == "WAITING_ON_CHILD", c)
    check("live child -> no action", c["action"] is None, c)
    c = cls(row(verdict="CHILD-STUCK", child={"age": 4000, "task": "x"},
                child_stale=3600, child_activity=3600))
    # ⛔ CHILD-STUCK IS PRESERVED, NOT COLLAPSED INTO CHILD-OVERDUE. The row says a child transcript
    # EXISTS and went quiet past the bound -- that is evidence, so the label survives and the lane
    # keeps its place in the unblock list. CHILD-OVERDUE is the verdict for "no child reachable at
    # all", which is UNKNOWN and prescribes NO action (asserted further down).
    check("child transcript quiet -> CHILD-STUCK (preserved, not collapsed)",
          c["verdict"] == "CHILD-STUCK", c)
    check("CHILD-STUCK -> unblock list (a transcript is evidence)", c["action"] == "wedged", c)
    # an unmatched task/subagent dispatch IS a child, even when lane-status dropped it as stale
    c = cls(row(verdict="WEDGED", tool={"name": "subagent", "age": 10200, "timeout": None}))
    check("unmatched subagent 2h50m -> CHILD-OVERDUE", c["verdict"] == "CHILD-OVERDUE", c)
    check("  and it is NOT sent to the words layer", c["step"] == "6", c)
    c = cls(row(tool={"name": "task", "age": 300, "timeout": None}))
    check("unmatched task 5m -> WAITING_ON_CHILD", c["verdict"] == "WAITING_ON_CHILD", c)

    print("Step 3 -- RETURNED vs UNMATCHED: the two states the child test cannot tell apart")
    # A dispatch that RETURNED and one that was CUT both leave NO child behind, so "no child
    # transcript" is not evidence of a cut. The parent's own transcript holds the difference: a
    # returned dispatch has a toolResult for its call id.
    RET = [rec_call("c1"), rec_result("c1")]
    fs_ret = FakeLS(files={"sid-1": "/fake/parent.jsonl"}, recs=RET)
    c = cls(row(verdict="WEDGED", tool={"name": "subagent", "age": 10200, "timeout": None}),
            LS=fs_ret)
    check("RETURNED dispatch -> NOT CHILD-OVERDUE", c["verdict"] != "CHILD-OVERDUE", c)
    check("RETURNED dispatch -> falls through to the words layer", c["step"] == "5", c)
    check("RETURNED dispatch -> the reason says so",
          any("RETURNED" in w for w in c["why"]), c)
    check("RETURNED dispatch -> no action is prescribed", c["action"] != "wedged", c)
    # ⛔ AND IT IS NOT REFUSED FOR A TOOL IT ALREADY PROVED SETTLED (review round 5, P3, MEASURED).
    # The snapshot's `tool` field can lag the transcript (cache TTL 420s, unbounded on the
    # STALE-SNAPSHOT path), so a lane whose dispatch demonstrably RETURNED still carried
    # `tool_in_flight=True` and `dispatch_refusal()` said "a tool call is in flight" directly under
    # this branch's own "the dispatch RETURNED" -- dropping an evidenced-idle lane from LIST 1.
    _ct = cls(row(verdict="DONE-IDLE", last="assistant",
                  tool={"name": "subagent", "age": 10200, "timeout": None}), LS=fs_ret)
    check("RETURNED dispatch -> tool_in_flight is cleared for the rest of the tree",
          _ct["tool_in_flight"] is False, _ct)
    check("  ...so the refusal never says a tool is in flight on a lane that proved it returned",
          "tool call is in flight" not in LA.dispatch_refusal(_ct), LA.dispatch_refusal(_ct))

    # ... and it must be the NEWEST dispatch that decides. An older call that returned says
    # nothing about a newer one still open -- pairing the wrong result is how a cut child gets
    # read as returned.
    MIXED = [rec_call("c1"), rec_result("c1"), rec_call("c2", ts="2026-10-05T11:00:00.000Z")]
    fs_mix = FakeLS(files={"sid-1": "/fake/parent.jsonl"}, recs=MIXED)
    c = cls(row(verdict="WEDGED", tool={"name": "subagent", "age": 10200, "timeout": None}),
            LS=fs_mix)
    check("older result does NOT clear a newer open dispatch",
          c["verdict"] == "CHILD-OVERDUE" and c["step"] == "6", c)

    # UNMATCHED (no result recorded) is reported -- but the wording must not claim a cut: nothing
    # readable here can see one. ⛔ AND IT IS NOT AN ACTION: CHILD-OVERDUE is UNKNOWN, so it must not
    # reach the unblock list. This is the defect that made the beat read
    # `WEDGED->1 unblock: 5&9 MCP and SDK surface` while that lane held a LIVE child (task in flight
    # 89m) -- following it interrupts live work.
    c = cls(row(verdict="WEDGED", tool={"name": "task", "age": 10200, "timeout": None}),
            LS=FakeLS(files={"sid-1": "/fake/parent.jsonl"}, recs=[rec_call("c1", "task")]))
    check("UNMATCHED dispatch -> reported as CHILD-OVERDUE",
          c["verdict"] == "CHILD-OVERDUE" and c["step"] == "6", c)
    check("  but CHILD-OVERDUE prescribes NO action (unknown != stall)",
          c["action"] is None, c)
    check("  wording says UNMATCHED, never CUT",
          any("UNMATCHED" in w for w in c["why"])
          and not any("a cut child looks exactly like this" in w for w in c["why"])
          and any("do NOT know it was cut" in w or "do not know it was cut" in w
                  for w in c["why"]), c)

    # STEP 6 recursion: an unmatched dispatch whose CHILD is demonstrably in flight is a lane
    # waiting correctly, not a wedge. This is the measured false positive this fix exists for.
    c = cls(row(verdict="CHILD-STUCK", tool={"name": "subagent", "age": 10200, "timeout": None},
                child={"age": 180}, child_grew=True),
            LS=FakeLS(files={"sid-1": "/fake/parent.jsonl"}, recs=[rec_call("c1")]))
    check("UNMATCHED dispatch + LIVE child -> WAITING_ON_CHILD",
          c["verdict"] == "WAITING_ON_CHILD" and c["action"] is None, c)
    check("  and the child evidence is carried in the why",
          any("child" in w for w in c["why"]), c)

    print("Step 4 -- age of the last tool call")
    c = cls(row(tool={"name": "bash", "age": 30, "timeout": None}))
    check("tool 30s -> TOOL-IN-FLIGHT", c["verdict"] == "TOOL-IN-FLIGHT", c)
    check("  no action", c["action"] is None, c)
    c = cls(row(tool={"name": "bash", "age": 4000, "timeout": 5000}))
    check("tool inside its declared budget -> TOOL-IN-FLIGHT", c["verdict"] == "TOOL-IN-FLIGHT", c)
    c = cls(row(tool={"name": "bash", "age": 200, "timeout": None}))
    check("tool 200s, no budget -> STEP 5", c["step"] == "5", c)
    c = cls(row(stale_s=60))
    check("recent output 60s -> TOOL-IN-FLIGHT", c["verdict"] == "TOOL-IN-FLIGHT", c)

    print("Step 5 -- only this step needs Jev, and its failure direction is REPORT ONLY")
    c = cls(row())
    check("quiet lane -> STEP 5 needs words", c["step"] == "5" and c["action"] == "words", c)

    print("Buckets -- PROTECTED, BUSY, and the partition invariant")
    rows = [
        row(lane="idle1", sid="sid-idle1", verdict="DONE-IDLE"),     # -> STEP 5
        row(lane="busy1", sid="sid-busy1", verdict="DONE-IDLE"),     # -> STEP 5
        row(lane="prot1", sid="sid-prot1", verdict="DONE-IDLE"),     # -> STEP 5
        row(lane="work1", sid="sid-work1", cpu=True),                 # -> WORKING
        row(lane="wait1", sid="sid-wait1", verdict="WAITING-CHILD",
            child={"age": 60}, child_grew=True),                       # -> WAITING
        row(lane="dead1", sid="sid-dead1", verdict="WEDGED"),        # -> DEAD
    ]
    files = {}
    for r in rows:
        r["cwd"] = fleet_cwd(r["lane"])          # a REAL fleet lane's evidence (see fleet_cwd)
        files[r["sid"]] = fleet_session(r["lane"])
    # every lane but dead1 has a live process in its session dir; wait1 also wrote recently, which on
    # its own settles existence (a dead process does not write a transcript).
    cwds = dict((str(i), fleet_cwd(r["lane"]))
                for i, r in enumerate(rows) if r["lane"] != "dead1")
    fs = FakeLS(files=files, cwds=cwds, cpus=dict(cwds))
    for r in rows:
        if r["lane"] == "wait1":
            r["stale_s"] = 60
    # `live` is pinned so this test does not depend on whatever cmux happens to have running: all
    # rows here carry the default ws="WS-1", and they must all stay live/actionable.
    res = LA.build(rows, fs, None, use_jev=False, live={"WS-1"}, spawn_markers=set())
    got = {c["lane"]: c for c in res["idle"] + res["wip"] + res["wedged"] + res["report"] + res["quiet"]}
    check("every lane lands in exactly one bucket", len(got) == len(rows),
          "%d vs %d" % (len(got), len(rows)))
    check("partition invariant: bucket sizes sum to the fleet",
          sum(len(res[k]) for k in ("idle", "wip", "wedged", "report", "quiet")) == len(rows))
    check("WORKING lane is in neither action list nor report",
          "work1" not in {c["lane"] for c in res["idle"] + res["wip"] + res["wedged"] + res["report"]})

    # ── IDLE IS REACHABLE ONLY THROUGH STEP 2 (#1867) ──────────────────────────────────────────
    # ⛔ THE MEASURED FALSE CAPACITY. The beat emitted
    #   `CAPACITY: 1 lane(s) idle >=20m with NO child in flight -- hand each the next unheld item`
    # for a lane whose CPU moved +4.93s in 25s and whose pane showed an active spinner; the lane's
    # record said `no session write for 13h34m`. A `task` CHILD is a second pi with the lane's cwd,
    # so the strict pid attribution answered None and Step 2 was skipped entirely -- the lane was
    # then judged on the transcript mtime. These two checks pin the veto and where it lands.
    print("Step 2 -- unattributed progress can never become free capacity (#1867)")
    c = cls(row(cpu=None, cpu_any=True, stale_s=48840, verdict="DONE-IDLE"))
    check("unattributed progress -> NOT the words layer", c["step"] == "2", c["step"])
    check("unattributed progress -> report only, never an action",
          c["verdict"] == "UNATTRIBUTED-WORKING" and c["action"] == "report", c)
    res_ua = LA.build([row(lane="ua1", cpu=None, cpu_any=True, stale_s=48840,
                           verdict="DONE-IDLE")],
                      FakeLS(files={"sid-1": "/x/s.jsonl"}), None, use_jev=False,
                      live={"WS-1"})
    check("unattributed progress never reaches the IDLE list",
          not res_ua["idle"], [c["lane"] for c in res_ua["idle"]])
    check("...and it is REPORTED rather than silently dropped",
          "ua1" in {c["lane"] for c in res_ua["report"]},
          [c["lane"] for c in res_ua["quiet"]])

    # PROVEN progress outranks a binding that could not be confirmed: the CPU reading is about the
    # LANE, not about which session file the pane was launched with (#1867).
    c = cls(row(cpu=True, session_verified=False))
    check("proven CPU progress -> WORKING, not an identity abstention",
          c["verdict"] == "WORKING" and c["step"] == "2", c)
    check("waiting-on-child lane needs nothing", "wait1" in {c["lane"] for c in res["quiet"]})
    check("no such process -> DEAD in the unblock list",
          "dead1" in {c["lane"] for c in res["wedged"]})
    check("words layer unread -> nothing is guessed into an action list",
          not res["idle"] and not res["wip"] and not res["words_read"])
    check("words layer unread -> the Step-5 lanes are REPORTED, not dropped",
          {"idle1", "busy1", "prot1"} <= {c["lane"] for c in res["report"]})
    check("JEV-DOWN is announced", "JEV-DOWN" in LA.render_beat(res, "state/NEEDS-ACTION.md"))
    # PROTECTED and BUSY suppression
    # ⛔ THE OWNER'S OWN WORKSPACE, WITH THE WORDS LAYER SAYING IT IS FINISHED. "Personal website"
    # is the measured defect (owner, 2026-10-20): it matched none of the old name list, so the
    # roster called it an idle fleet lane and the PR doctor dispatched a tortoise PR brief into it
    # -- twice. ⚠️ REVIEW ROUND 1 (P3): this pair of assertions was VACUOUS with `use_jev=False`,
    # because no lane can reach `idle` without a word label -- `not res2["idle"]` passed on the
    # PRE-FIX code too. The words layer is now stubbed to DONE_READY for every Step-5 lane, so the
    # ONLY difference between the two rows below is identity, and each half is the other's
    # non-vacuity.
    _real_jev5 = LA.jev_step5
    try:
        LA.jev_step5 = lambda step5, LV, enabled=True: (
            {c["lane"]: ("DONE_READY", 0.9) for c in step5},
            {"source": "JEV", "error": None, "model": "stub",
             "answered": len(step5), "asked": len(step5)})
        res2 = LA.build([row(lane="Personal website", sid="sid-p",
                             cwd="/Users/owner/Documents/Personal website"),
                         row(lane="fleet-lane", sid="sid-f", ws="WS-F",
                             cwd=fleet_wt("fleet-lane", 777))],
                        FakeLS(), None, use_jev=True, live=set(), spawn_markers=set())
    finally:
        LA.jev_step5 = _real_jev5
    check("the owner's OWN workspace is never offered as work, even when its words say DONE_READY",
          "Personal website" not in res2["dispatch_targets"], res2["dispatch_targets"])
    check("  ...non-vacuity: the SAME words label DOES make a fleet lane a dispatch target",
          res2["dispatch_targets"] == ["fleet-lane"], res2["dispatch_targets"])
    _own = [c for c in res2["report"] if c["lane"] == "Personal website"]
    check("PROTECTED reason is stated", bool(_own) and "PROTECTED" in _own[0]["why"][0],
          _own[0]["why"] if _own else "dropped")
    check("the reason names the EVIDENCE, not a name list",
          bool(_own) and "Personal website" in _own[0]["why"][0],
          _own[0]["why"][0] if _own else "dropped")
    # ⛔ ROUTED THROUGH THE STUBBED WORDS LAYER (review round 4, P3). The earlier version used
    # `use_jev=False`, under which NO lane can reach `idle` -- so its `not res2b["idle"]` half held on
    # the pre-fix code and under any identity rule at all, while the check's LABEL claimed the
    # identity rule. With the words stubbed DONE_READY, `dispatch_targets` is the only thing that can
    # answer the question the label asks.
    _jev5_for_harness = LA.jev_step5
    try:
        LA.jev_step5 = lambda step5, LV, enabled=True: (
            {c["lane"]: ("DONE_READY", 0.9) for c in step5},
            {"source": "JEV", "error": None, "model": "stub",
             "answered": len(step5), "asked": len(step5)})
        res2b = LA.build([row(lane="DMeer - linkedin outreach", sid="sid-p2")], FakeLS(),
                         None, use_jev=True, live=set(), spawn_markers=set())
    finally:
        LA.jev_step5 = _jev5_for_harness
    check("a legacy owner lane with an UNREADABLE cwd is never a dispatch target",
          res2b["dispatch_targets"] == [] and len(res2b["report"]) == 1, res2b["dispatch_targets"])
    # ⛔ AND THE UNION ITSELF (review round 1, P3): the ONLY place the historical names can change
    # an outcome is a legacy-named lane sitting in a FLEET worktree. Nothing tested that branch, so
    # deleting the union would have kept this suite green.
    res2c = LA.build([row(lane="DMeer - linkedin outreach", sid="sid-p3", ws="WS-D",
                          cwd=fleet_wt("legacy", 4242))], FakeLS(),
                     None, use_jev=False, live=set(), spawn_markers=set())
    _leg = [c for c in res2c["report"] if c["lane"].startswith("DMeer")]
    check("a legacy-named lane is PROTECTED even in a fleet worktree (the union still applies)",
          bool(_leg), res2c["idle"])
    check("  ...and the report says the name list is a UNION, not the mechanism",
          bool(_leg) and "ADDITIONAL union" in _leg[0].get("identity_why", ""),
          _leg[0].get("identity_why") if _leg else "dropped")

    # ── STEP 0: IDENTITY IS EVIDENCE, NOT A NAME LIST (owner, 2026-10-20) ────────────────────────
    # ⛔ THE MEASURED DEFECT, AS A REGRESSION FIXTURE. Protection was
    # `PROTECTED = ("DMeer", "DMer", "HANG")` matched by SUBSTRING against the lane's name. The
    # owner's workspace is titled **"Personal website"**, so it matched nothing, the roster
    # classified it as an idle fleet lane, and the PR doctor dispatched a tortoise PR brief INTO IT
    # -- twice, reported by the owner. Every assertion below fails on that implementation: it had no
    # notion of a cwd at all, so the owner's project path was as dispatchable as a worktree.
    print("")
    print("Step 0 -- identity is EVIDENCE (the fleet's worktree), never a name list")
    # ⛔ REVIEW ROUND 2 (P2), MEASURED: the `.worktrees` shape was accepted on its SPELLING alone,
    # so `/Users/owner/Documents/Personal website/.worktrees/preview` -- a directory the OWNER made
    # -- was a dispatch target, and pr-doctor's adopt arm could `reset --hard` inside it. A real
    # linked worktree is now REQUIRED (`git worktree add` writes `.git` as a FILE), so the fixtures
    # below are real directories on disk, not strings.
    _wtbase = tempfile.mkdtemp(prefix="lane-identity-")
    atexit.register(shutil.rmtree, _wtbase, ignore_errors=True)

    def _mkwt(rel):
        d = os.path.join(_wtbase, rel)
        os.makedirs(d)
        with open(os.path.join(d, ".git"), "w") as fh:
            fh.write("gitdir: /x/.git/worktrees/%s\n" % os.path.basename(rel))
        return d

    _repo = os.path.join(_wtbase, "GitHub", "tortoise")
    _real_wt = _mkwt(os.path.join("GitHub", "tortoise", ".worktrees", "prd-12"))
    _owner_wt = _mkwt(os.path.join("Personal website", ".worktrees", "preview"))
    _owner_proj = os.path.join(_wtbase, "Personal website")
    _plain_dot = os.path.join(_wtbase, "not-a-checkout", ".worktrees", "b")
    os.makedirs(_plain_dot)                                   # the spelling, with no worktree
    _main_co = os.path.join(_wtbase, "checkout")
    os.makedirs(os.path.join(_main_co, ".git"))              # a `.git` DIR: the main checkout

    check("the owner's project path is NOT a fleet worktree",
          LA._is_fleet_worktree(_owner_proj) is False)
    check("the shared checkout is NOT a fleet worktree (a lane must be a worktree)",
          LA._is_fleet_worktree(_main_co) is False)
    check("a bare lane-shaped NAME without a number is not a worktree",
          LA._is_fleet_worktree("/Users/owner/Documents/wt-later") is False)
    check("<repo>/.worktrees/<name> (a REAL linked worktree) IS a fleet worktree",
          LA._is_fleet_worktree(_real_wt) is True)
    # ⛔ A REAL worktree under a fleet root (the artifact `git worktree add` writes), never a path
    # that happens to exist on this box: the previous version cited `/tmp/cell-home/wt-123`, which
    # exists on exactly one machine, and `/tmp/wt-9204/scripts`, which was green only because that
    # path is a symlink here (review round 4, P2 -- a CI runner has neither).
    check("a real linked worktree under a fleet root IS a fleet worktree",
          LA._is_fleet_worktree(fleet_wt("harness-wt")) is True)
    check("  ...and the SAME path without its `.git` file is NOT (a name is not evidence)",
          LA._is_fleet_worktree(os.path.join(_wtbase, "GitHub", "tortoise", ".worktrees", "prd-13"))
          is False)
    # ⛔ REVIEW ROUND 1 (P2), MEASURED: the `wt-` branch used to require a DIGIT, so
    # `/tmp/cell-home/wt-4529-ai` was a fleet lane while `/tmp/cell-home/wt-lane-identity` -- this
    # lane's OWN linked worktree -- read as the OWNER's and was excluded from dispatch for ever.
    # The slug is not evidence of anything; being a child of the FLEET HOME is.
    check("a SLUG-named fleet worktree (<fleet root>/wt-<slug>) IS a fleet lane",
          LA._is_fleet_worktree(fleet_wt("slug-lane")) is True)
    check("  ...and so is a numbered one built the same way (no regression on wt-<n>)",
          LA._is_fleet_worktree(fleet_wt("numbered", 4529)) is True)
    check("a `wt-` name inside SOMEONE'S project is not a lane root",
          LA._is_fleet_worktree("/Users/owner/repo/wt-1-final-draft") is False)
    check("a path that only SPELLS like a lane is resolved before it is judged",
          LA._is_fleet_worktree("/Users/owner/wt-1/../../../Users/owner/Personal website") is False)
    check("`.worktrees` in the SPELLING is not enough: a plain directory is not a lane",
          LA._is_fleet_worktree(_plain_dot) is False)
    check("the KNOWN BOUNDARY: an owner's own REAL git worktree reads as a fleet worktree",
          LA._is_fleet_worktree(_owner_wt) is True)
    check("a subdirectory of a fleet worktree is still the fleet's",
          LA._is_fleet_worktree(os.path.join(_real_wt, "scripts")) is True)
    check("None is NOT a fleet worktree (fail-closed)", LA._is_fleet_worktree(None) is False)
    check("an EMPTY cwd is NOT a fleet worktree (fail-closed)",
          LA._is_fleet_worktree("  ") is False)
    check("a RELATIVE path is NOT a fleet worktree (nothing can be resolved against it)",
          LA._is_fleet_worktree("repo/wt-1") is False)
    check("identity: the owner's project path -> OWNER",
          LA.lane_identity({"lane": "Personal website", "cwd": "/Users/owner/Personal website"},
                           markers=set())[0] == "OWNER")
    check("identity: a real fleet worktree -> FLEET",
          LA.lane_identity({"lane": "L", "cwd": fleet_wt("harness-wt2")},
                           markers=set())[0] == "FLEET")
    check("identity: a row with NO readable cwd -> OWNER (never 'idle lane')",
          LA.lane_identity({"lane": "L"}, markers=set())[0] == "OWNER")
    check("...and the reason SAYS the cwd was unreadable, not that it was inspected",
          "UNREADABLE" in LA.lane_identity({"lane": "L"}, markers=set())[1],
          LA.lane_identity({"lane": "L"}, markers=set())[1])
    check("identity: a cwd under a fleet SPAWN MARKER -> FLEET",
          LA.lane_identity({"lane": "L", "cwd": "/srv/lanes/worker-7"},
                           markers={"/srv/lanes/worker-7"})[0] == "FLEET")
    check("a spawn marker for a DIFFERENT worktree does not make one the fleet's",
          LA.lane_identity({"lane": "L", "cwd": "/Users/owner/Personal website"},
                           markers={"/srv/lanes/worker-7"})[0] == "OWNER")

    # ── THE DISPATCH TARGET IS EVIDENCED IDLE (decision tree resolution order) ──────────────────
    # The tree: identity -> CPU delta -> child in flight -> tool age -> verdict. Anything WORKING /
    # TOOL-IN-FLIGHT / CHILD-* / UNBOUND / WEDGED is NOT a dispatch target, however quiet it looks.
    print("")
    print("The dispatch target is EVIDENCED idle -- WORKING/TOOL-IN-FLIGHT/CHILD-*/UNBOUND/WEDGED are not")

    def target(**kw):
        """A classified row with the identity fields `build()` sets, overridable per test.

        ⛔ `step` is NEVER forced. Which stage the classification STOPPED at is the whole point of
        the predicate (Step 2 = WORKING, Step 3 = child, Step 4 = tool, Step 0 = unbound), and a
        helper that forced `step="5"` would make every one of those cases pass by construction --
        the first version of this test did exactly that and reported 4 false PASSES.
        """
        c = cls(row(**kw))
        c["protected"], c["identity"], c["busy"] = False, "FLEET", False
        if c["step"] == "5":        # only a lane that REACHED the words layer can have words
            c["verdict"], c["conf"] = "DONE_READY", 0.9
        return c

    ok_t = target()
    check("the baseline row really does reach the words layer (non-vacuity)",
          ok_t["step"] == "5" and ok_t["mech"] == "DONE-IDLE", (ok_t["step"], ok_t["mech"]))
    check("DONE-IDLE + completed turn + no child + confident DONE_READY -> a dispatch target",
          LA.is_dispatch_target(ok_t) is True, LA.dispatch_refusal(ok_t))
    check("  ...and its refusal reason is empty, so nothing is printed about it",
          LA.dispatch_refusal(ok_t) == "")

    # each of these is a lane the tree says is NOT free, with the words layer claiming otherwise
    not_targets = [
        ("WORKING", target(cpu=True),
         "cpu True -> WORKING (Step 2, the strongest signal)"),
        ("TOOL-IN-FLIGHT", target(tool={"name": "bash", "age": 30, "timeout": None}),
         "a tool call 30s old (Step 4)"),
        # ⛔ REVIEW ROUND 3 (P3), MEASURED: BOTH clauses below were reachable but UNPINNED -- the
        # only tool fixture was 30s old, which stops at Step 4 (`step != 5`) and never reaches
        # `dispatch_refusal`'s own tool clause, and no fixture ever set `has_child` on a DONE-IDLE
        # row. Deleting either clause left the whole suite green.
        ("TOOL-IN-FLIGHT", target(tool={"name": "bash", "age": 300, "timeout": None}),
         "a tool call 300s old with no declared budget (reaches Step 5, refused by the tool clause)"),
        ("CHILD", target(child={"age": 9999, "task": "t"}),
         "a child transcript on a DONE-IDLE row (refused by the child clause)"),
        ("UNBOUND", target(sid=None), "no session binding at all (Step 0)"),
        ("WEDGED", target(verdict="WEDGED", spinner=True), "a WEDGED mechanical verdict"),
        ("CHILD", target(verdict="CHILD-STUCK", child={"age": 4000, "task": "x"},
                          child_stale=3600, child_activity=3600), "a stuck child transcript"),
        ("CHILD", target(verdict="WAITING-CHILD", child={"age": 60}, child_grew=True),
         "a live child in flight"),
        ("MIDTURN", target(last="tool"), "a turn that has NOT completed (last record is a call)"),
        ("BUSY", target(), "already auto-nudged this hour"),
    ]
    for name, c, label in not_targets:
        if name == "BUSY":
            c["busy"] = True
        if name == "UNBOUND":
            # identity is not knowable for an unbound row; keep it FLEET so the step-0 clause is the
            # one under test rather than the protection clause masking it
            c["identity"], c["protected"] = "FLEET", False
        check("%s is NEVER a dispatch target (%s)" % (label, name),
              LA.is_dispatch_target(c) is False, LA.dispatch_refusal(c))
        check("  ...and the refusal names its evidence",
              bool(LA.dispatch_refusal(c)), c)

    # the identity clause is checked BEFORE the state: the owner's workspace is not a target even
    # when it is DONE-IDLE and its words say it finished -- the measured dispatch into it
    own_t = target(lane="Personal website", cwd="/Users/owner/Personal website")
    own_t["protected"], own_t["identity"] = True, "OWNER"
    own_t["identity_why"] = "its session cwd /Users/owner/Personal website is NOT a fleet worktree"
    check("the owner's workspace is not a target even when it looks finished",
          LA.is_dispatch_target(own_t) is False)
    check("  ...and PROTECTED, not 'idle', is what the refusal says",
          "owner" in LA.dispatch_refusal(own_t).lower(), LA.dispatch_refusal(own_t))

    print("The beat clause is ONE line (cmux submits every newline as its own turn)")
    line = LA.render_beat(res, "state/NEEDS-ACTION.md")
    check("no newline in the beat clause", "\n" not in line, repr(line[:80]))
    check("the file pointer is in the clause", "NEEDS-ACTION.md" in line)
    check("the clause fits the beat budget and is not truncated",
          len(line) <= LA.SUMMARY_MAX and "\u2026" not in line, "%d chars" % len(line))

    # ── THE ACTION-SURFACE VETO: told work after its last output => NOT free capacity ─────────
    # ⛔ THE OWNER'S OWN WORDS: "Both of those were in the DO list telling me to act. Acting would
    # have interrupted live work." So this is asserted at the PUBLISHED-LINE level, not just on a
    # row: the beat must not be ABLE to say `IDLE->` about such a lane. `DONE_READY` is read from
    # the lane's own last WORDS, which cannot know a work order landed after they were written.
    print("The DO list is FAIL-CLOSED: a lane told work after its last output is not offered")
    _real_jev5 = LA.jev_step5
    try:
        LA.jev_step5 = lambda step5, LV, enabled=True: (
            {c["lane"]: ("DONE_READY", 0.9) for c in step5}, {"source": "JEV", "error": None})
        rows_fc = [
            # the fully-PAIRED measured instance (`Merigng PR`, 2026-10-11, read live): told 20m
            # ago (inbound_age=1210), silent for 5h14m (stale_s=18858), `task` still in flight.
            # The finding's `2a Projection keys` reading recorded only `latest_submitted 0.03h ago`
            # and NO output age, so its 108s is deliberately not paired with a `stale_s` anywhere.
            row(lane="told1", sid="sid-told1", verdict="DONE-IDLE", stale_s=18858,
                inbound_age=1210),
            # genuinely free: no inbound record at all
            row(lane="free1", sid="sid-free1", verdict="DONE-IDLE", stale_s=600,
                inbound_age=None),
            # told 27m ago but WROTE 25m ago -- the order was consumed, so it IS free
            row(lane="consumed1", sid="sid-consumed1", verdict="DONE-IDLE", stale_s=1500,
                inbound_age=1620),
        ]
        files_fc = dict((r["sid"], fleet_session(r["lane"])) for r in rows_fc)
        for r in rows_fc:
            r["cwd"] = fleet_cwd(r["lane"])
        cwds_fc = dict((str(i), fleet_cwd(r["lane"])) for i, r in enumerate(rows_fc))
        res_fc = LA.build(rows_fc, FakeLS(files=files_fc, cwds=cwds_fc, cpus=dict(cwds_fc)),
                          None, use_jev=False, live={"WS-1"}, spawn_markers=set())
        idles = {c["lane"] for c in res_fc["idle"]}
        check("a lane told work and silent since is NOT in the dispatch list",
              "told1" not in idles, sorted(idles))
        _t = [c for c in res_fc["report"] if c["lane"] == "told1"]
        check("...and is REPORTED instead, with the EVIDENCE named",
              bool(_t) and any("given work" in w for w in _t[0]["why"]),
              [c["why"][:1] for c in res_fc["report"]])
        check("a genuinely free lane STILL dispatches (the list is not empty by accident)",
              "free1" in idles, sorted(idles))
        check("a lane that ANSWERED what it was told is still free",
              "consumed1" in idles, sorted(idles))
        beat_fc = LA.render_beat(res_fc, "state/NEEDS-ACTION.md")
        _clause = beat_fc.split("|")[0]
        check("THE PUBLISHED LINE cannot name the withheld lane",
              "told1" not in _clause, _clause[:140])
        check("THE PUBLISHED LINE still dispatches both free lanes",
              "IDLE->2" in _clause and "free1" in _clause and "consumed1" in _clause,
              _clause[:160])
    finally:
        LA.jev_step5 = _real_jev5

    # ── the workspace-existence filter (tortoise#7738) ───────────────────────────────────────────
    # A lane whose cmux workspace no longer exists cannot be dispatched, unblocked or relaunched,
    # and its recorded words are from a lane that is GONE -- so it must never be offered as work and
    # must NEVER be routed to the owner as a decision. It is reported instead.
    print("")
    print("Workspace-existence filter -- no workspace means not actionable, and never routed")
    # WEDGED + no live process -> the `wedged` bucket, WITHOUT the words layer (the same construction
    # the dead1 case above uses). The `decoy` row WITH a process keeps the process map READABLE, which
    # is what makes "this lane has no process" decidable at all; with use_jev=False nothing is ever
    # guessed into `idle`, so a DONE-IDLE row could not prove anything about an action list.
    rows_f = [
        row(lane="decoy", sid="sid-decoy", cpu=True),
        row(lane="live1", sid="sid-live1", verdict="WEDGED", ws="WS-LIVE"),
        row(lane="gone1", sid="sid-gone1", verdict="WEDGED", ws="WS-GONE"),
    ]
    _files_f = dict((r["sid"], fleet_session(r["lane"])) for r in rows_f)
    for r in rows_f:
        r["cwd"] = fleet_cwd(r["lane"])
    _cwds_f = {"0": fleet_cwd("decoy")}
    fs_f = FakeLS(files=_files_f, cwds=_cwds_f, cpus=dict(_cwds_f))
    resf = LA.build(rows_f, fs_f, None, use_jev=False, live={"WS-LIVE"}, spawn_markers=set())
    action = {c["lane"] for c in resf["idle"] + resf["wip"] + resf["wedged"]}
    reported = {c["lane"] for c in resf["report"]}
    check("a lane whose workspace still exists stays actionable", "live1" in action)
    check("a lane whose workspace is GONE is never offered as work", "gone1" not in action)
    check("a lane whose workspace is GONE is REPORTED, not silently dropped", "gone1" in reported)
    check("the partition invariant survives the filter",
          sum(len(resf[k]) for k in ("idle", "wip", "wedged", "report", "quiet")) == len(rows_f))
    _g = [c for c in resf["report"] if c["lane"] == "gone1"]
    check("the reason names the missing workspace",
          bool(_g) and any("no longer exists" in w for w in _g[0]["why"]),
          _g[0]["why"] if _g else "gone1 absent from report")

    # ── CHILD-OVERDUE is NOT an action; CHILD-STUCK is ──────────────────────────────────────────
    # Measured 2026-10-11: the beat's ONE actionable line read
    # `WEDGED->1 unblock: 5&9 MCP and SDK surface` while that lane held a LIVE child
    # (`task in flight 89m`) -- acting on it interrupts live work. CHILD-OVERDUE means no child is
    # reachable from here, i.e. UNKNOWN, and an unknown must not become an instruction. CHILD-STUCK
    # has a transcript that EXISTS and went quiet past the bound -- that is evidence, so it keeps
    # its place in the unblock list. The rule is about the BEAT, so it is asserted at bucket level,
    # not only on the row's `action`.
    print("")
    print("CHILD-OVERDUE is UNKNOWN -> report-only;  CHILD-STUCK has evidence -> unblock list")
    rows_c = [
        row(lane="decoyc", sid="sid-decoyc", cpu=True),
        row(lane="overdue1", sid="sid-overdue1", verdict="CHILD-OVERDUE", ws="WS-C",
            child={"age": 4000, "task": "x"}),
        row(lane="stuck1", sid="sid-stuck1", verdict="CHILD-STUCK", ws="WS-C",
            child={"age": 4000, "task": "x"}, child_stale=3600, child_activity=3600),
    ]
    _files_c = dict((r["sid"], fleet_session(r["lane"])) for r in rows_c)
    for r in rows_c:
        r["cwd"] = fleet_cwd(r["lane"])
    _cwds_c = dict((str(i), fleet_cwd(r["lane"])) for i, r in enumerate(rows_c))
    fs_c = FakeLS(files=_files_c, cwds=_cwds_c, cpus=dict(_cwds_c))
    resc = LA.build(rows_c, fs_c, None, use_jev=False, live={"WS-C"}, spawn_markers=set())
    _act_c = {c["lane"] for c in resc["idle"] + resc["wip"] + resc["wedged"]}
    _rep_c = {c["lane"] for c in resc["report"]}
    check("CHILD-OVERDUE is NOT offered for an unblock", "overdue1" not in _act_c)
    check("CHILD-OVERDUE is still REPORTED (the evidence is kept, not dropped)",
          "overdue1" in _rep_c)
    check("CHILD-STUCK keeps its place in the unblock list", "stuck1" in _act_c)
    check("the partition invariant survives the child-overdue move",
          sum(len(resc[k]) for k in ("idle", "wip", "wedged", "report", "quiet")) == len(rows_c))
    # ⛔ THE UUID SURVIVED; THE LANE DID NOT (2026-10-10, #7957 H4). Measured LIVE: three of the six
    # lanes the beat offered as IDLE had a live UUID under a DIFFERENT title -- `land-6260` was
    # `P1 data-loss`, `Merigng PR` was `PR 2`, `\u03c0 - land-lane-1` was `5285 Decision`. The
    # UUID-existence check passed all three, so the beat spent dispatches on lanes that are not there.
    # The title is the lane's identity; the UUID is only its key.
    rows_n = [
        row(lane="land-6260", sid="sid-renamed", verdict="WEDGED", ws="WS-RENAMED"),
        row(lane="land-lane-3", sid="sid-same", verdict="WEDGED", ws="WS-SAME"),
    ]
    _files_n = dict((r["sid"], fleet_session(r["lane"])) for r in rows_n)
    for r in rows_n:
        r["cwd"] = fleet_cwd(r["lane"])
    fs_n = FakeLS(files=_files_n, cwds={"0": fleet_cwd("decoy")}, cpus={"0": fleet_cwd("decoy")})
    resn = LA.build(rows_n, fs_n, None, use_jev=False, spawn_markers=set(),
                    live={"WS-RENAMED": "P1 data-loss", "WS-SAME": "land-lane-3"})
    act_n = {c["lane"] for c in resn["idle"] + resn["wip"] + resn["wedged"]}
    rep_n = [c for c in resn["report"] if c["lane"] == "land-6260"]
    check("H4: a lane whose workspace was RENAMED is never offered as work", "land-6260" not in act_n)
    check("H4: ...and it is REPORTED, not silently dropped", bool(rep_n))
    check("H4: ...and the reason names the CURRENT title, not just the uuid",
          bool(rep_n) and any("P1 data-loss" in w for w in rep_n[0]["why"]),
          rep_n[0]["why"] if rep_n else "land-6260 absent from report")
    check("H4: a lane whose workspace KEPT its name stays actionable", "land-lane-3" in act_n)
    # UNKNOWN titles (a legacy UUID-only published list) must NEVER filter -- upgrading the consumer
    # before the publisher must not be able to hide a real lane.
    resu = LA.build(rows_n, fs_n, None, use_jev=False, live={"WS-RENAMED": "", "WS-SAME": ""},
                    spawn_markers=set())
    act_u = {c["lane"] for c in resu["idle"] + resu["wip"] + resu["wedged"]}
    check("H4: an UNKNOWN title filters nothing (fail-open on a legacy list)",
          "land-6260" in act_u and "land-lane-3" in act_u)

    # POLARITY: an unreadable workspace list must filter NOTHING, so a cmux hiccup can never hide a
    # real lane. This is also the exact bug that shipped first: a swallowed NameError made the live
    # set empty and the filter a silent no-op that LOOKED like it worked.
    resu = LA.build(rows_f, fs_f, None, use_jev=False, live=set(), spawn_markers=set())
    actionu = {c["lane"] for c in resu["idle"] + resu["wip"] + resu["wedged"]}
    check("an unreadable workspace list filters NOTHING (fail-open)", "gone1" in actionu)
    # ⛔ These next tests exercise the cmux FALLBACK, so the published-file source MUST be
    # neutralised: the file is real and fresh on this box, so it answers first and the fallback is
    # never reached. (The first run of this suite after adding the file source failed for exactly that
    # reason -- a test that silently stops testing what it names is worse than no test.)
    _saved_wsfile = LA.LIVE_WS_FILE
    LA.LIVE_WS_FILE = "/nonexistent/live-workspaces.txt"

    # POLARITY, tested against the exact bug that shipped first: a NameError inside the body was
    # swallowed into "cmux unreadable", making the live set empty and the filter a silent no-op.
    class _Shim:
        """Stands in for the `subprocess` module, raising whichever error it is handed."""

        def __init__(self, exc):
            self._exc = exc

        def run(self, *a, **k):
            raise self._exc

    _orig = LA.subprocess
    try:
        LA.subprocess = _Shim(NameError("subprocess is not defined"))
        _raised = False
        try:
            LA.live_workspaces()
        except NameError:
            _raised = True
        check("a programming error inside live_workspaces RAISES (never a silent empty set)",
              _raised)
        LA.subprocess = _Shim(OSError("cmux not found"))
        check("a genuine I/O failure DOES fail open to an empty set",
              LA.live_workspaces() == {})
    finally:
        LA.subprocess = _orig

    # ⛔ cmux MUST resolve by ABSOLUTE path. The beat runs under launchd with the default PATH
    # (/usr/gnu/bin:/usr/local/bin:/bin:/usr/bin:.), which does NOT contain cmux -- a bare PATH
    # lookup raised FileNotFoundError, the fail-open polarity read that as "cmux unreadable", and the
    # filter silently did NOTHING in production while passing every other test here. This assertion
    # is the one that would have caught it.
    _cb = LA.cmux_bin()
    check("cmux_bin() returns an ABSOLUTE executable path (not a bare PATH lookup)",
          _cb.startswith("/") and os.path.isfile(_cb) and os.access(_cb, os.X_OK), _cb)
    _saved_c = LA.CMUX_CANDIDATES
    try:
        LA.CMUX_CANDIDATES = ("/nonexistent/cmux",)
        check("cmux_bin() falls back to a PATH lookup only when no absolute candidate exists",
              LA.cmux_bin() == "cmux")
    finally:
        LA.CMUX_CANDIDATES = _saved_c

    # ⛔ THE BUG THAT FOOLED ME TWICE, tested directly: from launchd, cmux exits 1 with EMPTY stdout
    # ("Access denied - only processes started inside cmux can connect"). The empty stdout parsed as
    # `{}` -> no workspaces -> `set()`, so the function returned WITHOUT RAISING, the except branch
    # never ran, and the filter was silently inert in the beat while working in every shell started
    # inside cmux. It must fail open AND say so -- an inert filter that looks like a working one is
    # precisely the hazard this function exists to remove.
    import contextlib
    import io

    class _Result:
        def __init__(self, rc, out, err=""):
            self.returncode, self.stdout, self.stderr = rc, out, err

    class _RcShim:
        def __init__(self, res):
            self._res = res

        def run(self, *a, **k):
            return self._res

    _saved = LA.subprocess
    try:
        _buf = io.StringIO()
        LA.subprocess = _RcShim(_Result(
            1, "", "ERROR: Access denied - only processes started inside cmux can connect"))
        with contextlib.redirect_stderr(_buf):
            _got = LA.live_workspaces()
        check("cmux exiting non-zero with EMPTY stdout fails open to an empty set", _got == {})
        check("...and SHOUTS, so an inert filter can never look like a working one",
              "INERT" in _buf.getvalue() and "Access denied" in _buf.getvalue(),
              _buf.getvalue()[:120])
        LA.subprocess = _RcShim(_Result(0, '{"workspaces":[{"id":"WS-A","title":"Lane A"}]}'))
        # The value is now UUID -> TITLE: the title is the lane's identity, the UUID only its key.
        check("a clean non-empty response is parsed (rc=0, ids uppercased, title captured)",
              LA.live_workspaces() == {"WS-A": "Lane A"})
        LA.subprocess = _RcShim(_Result(0, '{"workspaces":[{"id":"WS-A"}]}'))
        check("...a response with NO title reads that title as UNKNOWN (never filtered on)",
              LA.live_workspaces().get("WS-A") == "")
        LA.subprocess = _RcShim(_Result(0, ""))
        _buf2 = io.StringIO()
        with contextlib.redirect_stderr(_buf2):
            LA.live_workspaces()
        check("rc=0 with EMPTY stdout is treated as a failure too (not as 'no workspaces')",
              "INERT" in _buf2.getvalue())
    finally:
        LA.subprocess = _saved

    # ── the PUBLISHED-FILE source: the one that actually works from launchd (tortoise#7738) ──────
    # The beat cannot query cmux at all -- "Access denied - only processes started inside cmux can
    # connect" -- so this source is what makes the filter work where it matters. The file is written
    # by scripts/publish-live-workspaces.py from inside cmux.
    LA.LIVE_WS_FILE = _saved_wsfile
    _tmpd = tempfile.mkdtemp()
    _tf = os.path.join(_tmpd, "live-workspaces.txt")
    _saved_wsfile2 = LA.LIVE_WS_FILE
    LA.LIVE_WS_FILE = _tf
    try:
        with open(_tf, "w") as fh:
            fh.write("# a comment line\nWS-PUB-1\tLane One\nWS-PUB-2\tLane Two\n")
        check("a published file is the primary source (no cmux needed)",
              LA.live_workspaces() == {"WS-PUB-1": "Lane One", "WS-PUB-2": "Lane Two"})
        # BACKWARD COMPAT: a LEGACY UUID-only line must still parse, but must yield an UNKNOWN
        # title -- so a publisher that has not been upgraded can never start hiding live lanes.
        with open(_tf, "w") as fh:
            fh.write("# legacy format\nWS-PUB-1\nWS-PUB-2  (a trailing title is fine)\n")
        check("...a legacy UUID-only line still parses, with an UNKNOWN title",
              LA.live_workspaces() == {"WS-PUB-1": "",
                                       "WS-PUB-2": "(a trailing title is fine)"})
        with open(_tf, "w") as fh:
            fh.write("# a comment line\nWS-PUB-1\tLane One\nWS-PUB-2\tLane Two\n")
        # STALE: older than the window is NOT evidence about the live fleet. It falls back to cmux,
        # which works when the caller is inside cmux -- so test BOTH branches.
        _old = time.time() - (LA.LIVE_WS_MAX_AGE_S + 60)
        os.utime(_tf, (_old, _old))
        LA.subprocess = _RcShim(_Result(0, '{"workspaces":[{"id":"WS-CMUX"}]}'))
        check("a stale published file FALLS BACK to cmux (which works inside cmux)",
              LA.live_workspaces() == {"WS-CMUX": ""})
        # ...and when cmux is unusable too (the BEAT's situation), it must fail open AND say why.
        LA.subprocess = _RcShim(_Result(1, "", "Access denied - only processes inside cmux"))
        _buf3 = io.StringIO()
        with contextlib.redirect_stderr(_buf3):
            _stale = LA.live_workspaces()
        check("stale file + unusable cmux -> empty (fail-open, the beat's real case)",
              _stale == {})
        check("...and the staleness is reported, never silent",
              "INERT" in _buf3.getvalue() and "old" in _buf3.getvalue(),
              _buf3.getvalue()[:140])
        # AN EMPTY published file is a failure too, not "no workspaces"
        open(_tf, "w").close()
        _buf4 = io.StringIO()
        with contextlib.redirect_stderr(_buf4):
            LA.live_workspaces()
        check("an EMPTY published file + unusable cmux is a failure, not 'no workspaces'",
              "INERT" in _buf4.getvalue())
    finally:
        LA.LIVE_WS_FILE = _saved_wsfile2
        shutil.rmtree(_tmpd, ignore_errors=True)   # module-level `shutil`, never a local import

    # ── THE DEPLOYMENT COUPLING, PINNED ─────────────────────────────────────────────────────────
    # ⛔ `LS_PATH` resolves to the DEPLOYED `~/.pi/agent/scripts/lane-status.py`, NOT the copy beside
    # this file, and the two deploy INDEPENDENTLY. Calling the sibling's new predicate directly
    # crashed the live beat with `AttributeError: module 'lane_status' has no attribute
    # 'told_but_silent'` the moment lane-actions.py landed first (reproduced 2026-10-12: exit 1, no
    # beat produced). So the rule is stated locally as a fallback -- and a duplicated predicate
    # drifts unless something pins it, which is this.
    print("The deployed-sibling fallback matches the canonical rule")
    _grid = [(None, None), (None, 1), (1, None), (0, 0), (1, 2), (2, 1), (1210, 18858),
             (1620, 1500), (36, 3), (10800, 20000), (600, 600)]
    _mismatch = [(ia, st, LS_MOD.told_but_silent(ia, st), LA.told_but_silent(ia, st))
                 for ia, st in _grid if LS_MOD.told_but_silent(ia, st) != LA.told_but_silent(ia, st)]
    check("the local fallback agrees with the canonical rule on every input",
          not _mismatch, _mismatch)

    class _WithFn:
        @staticmethod
        def told_but_silent(ia, st):
            return "sibling"

    class _WithoutFn:
        pass

    check("the selector PREFERS the sibling when present (a future rule change takes effect)",
          LA.told_but_silent_via(_WithFn) is _WithFn.told_but_silent)
    check("the selector degrades to the SAME RULE against an older deployed sibling",
          LA.told_but_silent_via(_WithoutFn) is LA.told_but_silent
          and LA.told_but_silent_via(object()) is LA.told_but_silent)

    print("The recap/beat pair is BOUND, not merely written twice (#7957 H3)")
    # The defect: `.md` and `.beat` are two independent atomic writes, so a failure between them
    # left a FRESH recap beside a STALE beat -- two numbers, one tick -- and the beat is the half
    # the floor reads. The fix binds them with `md=<digest of the recap this beat was rendered
    # from>` and exits NON-ZERO on a tear so no caller can read a torn tick as a success.
    _pd = os.path.join(_STATE_SCRATCH, "pair")
    os.makedirs(_pd, exist_ok=True)

    def _pair(tag):
        return (os.path.join(_pd, "recap-%s.md" % tag),
                os.path.join(_pd, "recap-%s.beat" % tag))

    # 1. Both halves published, and the beat NAMES the recap it was rendered from.
    mp, bp = _pair("a")
    rc = LA.write_pair(mp, "# recap A\n", "DO: X", True, beat_path=bp)
    beat_txt = open(bp).read()
    want = hashlib.sha256(b"# recap A\n").hexdigest()[:LA.MD_SHA_LEN]
    check("write_pair publishes both halves (rc 0)", rc == 0, rc)
    check("the beat carries md=<digest of the recap>", "md=%s\n" % want in beat_txt, beat_txt)
    check("actfull reflects words_read=True", "actfull=1\n" in beat_txt, beat_txt)
    check("the digest length is the pinned MD_SHA_LEN", len(want) == LA.MD_SHA_LEN == 12, want)

    # 2. The digest BINDS CONTENT -- not a constant, not the mtime.
    mp2, bp2 = _pair("b")
    LA.write_pair(mp2, "# recap B\n", "DO: X", True, beat_path=bp2)
    check("a different recap yields a different digest (the binding is content)",
          open(bp2).read() != beat_txt, open(bp2).read())

    # 3. TORN: the beat cannot be written -> rc 4, NEVER 0. The recap IS published, which is
    #    precisely why the pair is torn, and the stale beat is left as the evidence.
    mp3, bp3 = _pair("c")
    with open(mp3, "w") as fh:
        fh.write("# OLD recap\n")
    with open(bp3, "w") as fh:
        fh.write("act=OLD\nactfull=1\nmd=deadbeefdead\n")
    rc = LA.write_pair(mp3, "# NEW recap\n", "DO: NEW", True,
                       beat_path=os.path.join(_pd, "no-such-dir", "x.beat"))
    check("a beat-write failure returns 4, never 0 (the pair is TORN)", rc == 4, rc)
    check("...the RECAP was published, which is exactly why it is torn",
          "NEW recap" in open(mp3).read(), open(mp3).read())
    check("...and the beat keeps the OLD digest, so a reader can TELL it is stale",
          open(bp3).read() == "act=OLD\nactfull=1\nmd=deadbeefdead\n", open(bp3).read())

    # 4. NOT torn: the recap cannot be written -> rc 3, and the beat is left ALONE so the
    #    published pair stays consistent (a beat written first would tear it the other way).
    mp4, bp4 = _pair("d")
    with open(bp4, "w") as fh:
        fh.write("act=KEEP\nactfull=1\nmd=keepkeepkeep\n")
    rc = LA.write_pair(os.path.join(_pd, "no-such-dir", "y.md"), "# nunca\n", "DO: N", True,
                       beat_path=bp4)
    check("a recap-write failure returns 3", rc == 3, rc)
    check("...and the beat is UNTOUCHED, so the published pair remains consistent",
          open(bp4).read() == "act=KEEP\nactfull=1\nmd=keepkeepkeep\n", open(bp4).read())

    # 5. The Jev-outage degradation is carried through the binding.
    mp5, bp5 = _pair("e")
    LA.write_pair(mp5, "# recap E\n", "DO: E", False, beat_path=bp5)
    check("actfull=0 when the words layer was NOT read",
          "actfull=0\n" in open(bp5).read(), open(bp5).read())

    print("")
    if FAILS:
        print("FAILED %d: %s" % (len(FAILS), ", ".join(FAILS)))
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())


# ── #7871: the ACTION vocabulary that replaced `blocked` ───────────────────────────────
# `blocked` counted `mergeStateStatus=BLOCKED`, which GitHub emits for several unrelated
# conditions, and needed a sentence of apology to say so. These tests hold the replacement:
# each non-draft PR lands in EXACTLY ONE action bucket, and the classification says what to
# DO rather than what state a PR is in.
def _objective_mod():
    import importlib.util, pathlib
    path = pathlib.Path(__file__).with_name("objective.py")
    spec = importlib.util.spec_from_file_location("objective_uv", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)          # the __main__ guard keeps this side-effect free
    # ⛔ "SIDE-EFFECT FREE" WAS TRUE OF LOADING AND FALSE OF THE CALLS THAT PERSIST STATE (#1734).
    # `objective.py` persists state
    # BETWEEN HEARTBEAT BEATS, and `STUCK_FILE` resolves to
    # `~/.pi/agent/state/call-rail-stuck.json` -- the file the live loop maintains to escalate a
    # call-rail PR that has gone quiet. Measured: a run of this file wrote it three times and then
    # REMOVED it -- so the suite could delete the operator's live state.
    #
    # Redirected HERE, where the module is loaded, rather than in a single test: `_objective_mod()`
    # mints a FRESH module object per call (`module_from_spec`), so a redirect applied to one caller
    # leaves every other caller -- and every class added later -- writing the real file. One seam,
    # every consumer. `test_the_suite_never_points_at_the_production_state_dir` pins the redirect, so
    # deleting it fails instead of silently resuming the writes.
    mod.STATE = _STATE_SCRATCH
    mod.CACHE = os.path.join(_STATE_SCRATCH, "objective.last")
    mod.STUCK_FILE = os.path.join(_STATE_SCRATCH, "call-rail-stuck.json")
    return mod


class TestActionVocabulary:
    @classmethod
    def setup_class(cls):
        cls.o = _objective_mod()
        cls.REQ = list(cls.o.REQUIRED)
        cls.DU = "https://github.com/o/r/actions/runs/1/job/2"

    def test_the_suite_never_points_at_the_production_state_dir(self):
        """⛔ THE REDIRECT MUST BE IN FORCE, NOT MERELY PRESENT (#1734). Deleting the `STUCK_FILE`
        line in `_objective_mod()` must fail HERE, or the next edit that removes it silently resumes
        writing -- and deleting -- a file the heartbeat loop owns.

        Asserted on the module `_objective_mod()` returns, which is the seam every class in this file
        loads through, so this pins the redirect rather than one class's copy of it."""
        state = os.path.expanduser("~/.pi/agent/state")
        for name in ("STATE", "CACHE", "STUCK_FILE"):
            value = getattr(self.o, name)
            assert not value.startswith(state), f"{name} points at production: {value}"

    def _cr(self, red=(), absent=(), extra_red=(), flight=()):
        """A check-run list for the 7 required contexts, plus optional never-required reds.

        `flight` builds IN-FLIGHT attempts (`status=in_progress`), which is a different fact from
        green, red, and absent -- and the one the classifier used to get wrong (#1872). A flight
        name that is NOT a required context becomes its own check-run, because that is the live
        shape: `python-ci-gate` is ABSENT while its child jobs run.
        """
        out, i = [], 0
        for n in self.REQ:
            if n in absent:
                continue
            i += 1
            out.append({"id": i, "name": n,
                        "status": "in_progress" if n in flight else "completed",
                        "conclusion": None if n in flight else (
                            "failure" if n in red else "success"),
                        "app": {"slug": "actions"}, "details_url": self.DU})
        for n in self.o.RAIL_GATES:            # the rail's own gates ride along, GREEN
            i += 1
            out.append({"id": i, "name": n, "status": "completed", "conclusion": "success",
                        "app": {"slug": "actions"}, "details_url": self.DU})
        for j, n in enumerate(extra_red):
            out.append({"id": 900 + j, "name": n, "status": "completed",
                        "conclusion": "failure", "app": {"slug": "actions"},
                        "details_url": self.DU})
        for j, n in enumerate([x for x in flight if x not in self.REQ]):
            # A NON-required check in flight is its own check-run -- the live shape is
            # `python-ci-gate` ABSENT while its child jobs (`test (a)`, ...) run.
            out.append({"id": 950 + j, "name": n, "status": "in_progress",
                        "conclusion": None, "app": {"slug": "actions"},
                        "details_url": self.DU})
        return out

    def _pr(self, ms="BLOCKED", files=None):
        return {"number": 1, "isDraft": False, "mergeStateStatus": ms,
                "headRefOid": "a" * 40, "files": files or []}

    def test_ai_review_gate_only_red_is_record_review_not_fix_ci(self):
        assert self.o.classify_pr(self._pr(), self._cr(red=["ai-review-gate"]), False) \
            == "record-review"

    def test_dirty_is_resolve_conflict(self):
        """A conflicted PR whose checks are not all green -- the normal case."""
        cr = self._cr(red=["python-ci-gate"])
        assert self.o.classify_pr(self._pr(ms="DIRTY"), cr, False) == "resolve-conflict"

    def test_knows_the_one_edge_the_strict_order_creates(self):
        """PINNED, NOT ENDORSED: `call-rail` is FIRST in CLASS_ORDER, so a PR that is BOTH
        fully green+attested AND `DIRTY` classifies `call-rail` -- which the rail would then
        REFUSE on the conflict. The spec fixes the order, so the order is implemented exactly
        as written; this test exists so the edge is visible rather than discovered in the field."""
        assert self.o.classify_pr(self._pr(ms="DIRTY"), self._cr(), True) == "call-rail"

    def test_non_required_reds_change_nothing(self):
        """`drive`/`sigpipe-guard` are red on main BY DESIGN -- never a bucket."""
        cr = self._cr(extra_red=["drive", "sigpipe-guard"])
        assert self.o.classify_pr(self._pr(), cr, True) == "call-rail"

    def test_no_required_check_ever_ran_is_rerun_checks(self):
        assert self.o.classify_pr(self._pr(), self._cr(absent=self.REQ), False) \
            == "rerun-checks"

    def test_NOTHING_reported_yet_while_checks_RUN_is_running_not_rerun(self):
        """⛔ ARM 2 MUST CONCEDE TO ARM 4 (#1872 review -- a real defect found in review).

        A fresh head where NO required context has reported yet while other checks are already
        in flight is the NORMAL first state of a push (`python-ci-gate`, `docs` and `legal-e2e`
        are created seconds after the children). `not req_seen` cannot tell "not reported yet"
        from "never ran", and the two need OPPOSITE actions: wait, versus START the workflow.

        Before the fix arm 2 fired first and this shape read `rerun-checks`; the dispatcher's
        brief for that class asserts "(Nothing is in flight ...)" and tells the lane to push an
        empty commit -- so a 20-second-old head was churned, wasting runner capacity and staling
        every attestation.
        """
        cr = self._cr(absent=self.REQ, flight=["test (a)"])
        assert self.o.classify_pr(self._pr(), cr, False) == "running"
        # ...and once NOTHING is in flight, the same absence is still the re-trigger work
        assert self.o.classify_pr(self._pr(), self._cr(absent=self.REQ), False) \
            == "rerun-checks"

    def test_green_with_attestation_is_call_rail_without_is_record_review(self):
        assert self.o.classify_pr(self._pr(), self._cr(), True) == "call-rail"
        assert self.o.classify_pr(self._pr(), self._cr(), False) == "record-review"

    def test_unreadable_is_none_and_never_fix_ci(self):
        assert self.o.classify_pr(self._pr(), None, True) is None

    def test_rerun_adds_a_red_it_does_not_clear_one(self):
        cr = self._cr()
        cr.append(dict(cr[0], conclusion="failure", id=999))     # a LATER red, same job
        assert self.o.classify_pr(self._pr(), cr, True) == "fix-ci"
        cr2 = self._cr()
        cr2.append(dict(cr2[0], conclusion="failure", id=1))     # a SUPERSEDED red
        cr2.append(dict(cr2[0], conclusion="success", id=999))
        assert self.o.classify_pr(self._pr(), cr2, True) == "call-rail"

    def test_surface_overlay_is_not_a_sixth_bucket(self):
        assert self.o.touches_surface(self._pr(files=[{"path": "tortoise/sdk.py"}])) is True
        assert self.o.touches_surface(self._pr(files=[{"path": "README.md"}])) is False

    def test_diff_bound_gate_does_not_gate_call_rail(self):
        """#7960 IS THE LIVE FIXTURE. `ai-review-gate` is DIFF-BOUND: it is RED by construction
        on any PR whose record was written AFTER its last run (measured 2026-10-10: red on 8 of
        11 open PRs, #7960 included, WHICH ALREADY CARRIED A CURRENT CLEAN ATTESTATION).
        Requiring all 7 green therefore made `call-rail` DEAD CODE and dropped a fully-attested,
        one-rail-call-from-landing PR into `record-review` -- telling a lane to RE-RECORD a head
        that WAS recorded, which DILUTES the evidence and, by touching the PR body, WIPES the
        attestation. This test FAILS on the pre-correction code and passes only when the
        head-bound FILE, not the check-run, decides."""
        cr = self._cr(red=["ai-review-gate"])
        assert self.o.classify_pr(self._pr(), cr, True) == "call-rail"      # #7960
        assert self.o.classify_pr(self._pr(), cr, False) == "record-review"  # legitimate case

    def test_a_real_failure_still_outranks_the_attestation(self):
        """An attestation never launders a genuinely failing check into a landing."""
        cr = self._cr(red=["ai-review-gate", "python-ci-gate"])
        assert self.o.classify_pr(self._pr(), cr, True) == "fix-ci"

    def test_attested_but_rail_refused_is_a_NAMED_defect_not_call_rail(self):
        """THE FALSE POSITIVE. `call-rail=1: #7924 (STUCK 3 beats)` sent a lane to a rail that
        REFUSED #7924 for flip-gate/drift-guard -- three hours of a token with nothing landable
        behind it. An attested, rail-refused PR is not 'not ready'; it is a named defect."""
        cr = self._cr()
        cr.append({"id": 500, "name": "drift-guard", "status": "completed",
                   "conclusion": "failure", "app": {"slug": "actions"}, "details_url": self.DU})
        assert self.o.classify_pr(self._pr(), cr, True) == "blocked-by-rail"
        red, fl = self.o.rollup_checks(cr)
        seen = {c.get("name") for c in cr if c.get("name")}
        assert self.o.rail_block_reason(red, fl, seen) == "drift-guard"
        # ...and the reason is RENDERED, so a lane knows WHAT to fix
        tok = self.o._class_token("blocked-by-rail", 1, [(7924, "drift-guard")])
        assert "#7924(drift-guard)" in tok

    def test_a_rail_clean_attested_pr_is_still_call_rail(self):
        assert self.o.classify_pr(self._pr(), self._cr(), True) == "call-rail"

    def test_a_non_required_check_never_reaches_the_DO_list(self):
        """A readout that sends lanes at useless work is a defect with a measurable cost: it burned
        lane cycles chasing `agent-infra-ci / lint` (a job that trips its OWN guard and reports its
        own success as a failure) and job names like `test (b)` that live INSIDE the one required
        context `python-ci-gate` and therefore gate nothing on their own."""
        cr = self._cr(red=["python-ci-gate"])
        for i, nm in enumerate(("drive", "agent-infra-ci / lint", "test (b)", "manifest-integrity")):
            cr.append({"id": 700 + i, "name": nm, "status": "completed",
                       "conclusion": "failure", "app": {"slug": "actions"}, "details_url": self.DU})
        got = self.o.fix_ci_reasons(cr)
        assert got == ["python-ci-gate"], got          # ONLY the required context
        for banned in ("drive", "agent-infra-ci / lint", "test (b)", "manifest-integrity"):
            assert banned not in got, banned

    def test_a_required_check_that_never_ran_is_rerun_work_NOT_fix_ci_work(self):
        """Absence is not green, and it is not a FAILURE to repair either.

        A required check that never ran has to be STARTED, so the PR is `rerun-checks`. It used
        to be counted in `fix_ci_reasons` as well -- while `fix-ci` was the catch-all -- which
        told a lane to FIX a check that had never executed. Since the partial-absence arm gives
        it its own class (#1872), the reasons list is RED ONLY.
        """
        cr = self._cr(absent=["docs"])
        assert self.o.classify_pr(self._pr(), cr, False) == "rerun-checks"
        assert "docs" not in self.o.fix_ci_reasons(cr)

    def test_a_check_still_in_flight_is_running_not_fix_ci(self):
        """MEASURED LIVE, #8825 (2026-10-16). `pricing-artifact` was mid-run, `ai-review-gate`
        red, `python-ci-gate` not yet created, and the beat printed it in the fix-ci bucket -- i.e.
        it told a lane to go FIX code under a suite that was still executing. Waiting is the
        action: none."""
        cr = self._cr(red=["ai-review-gate"], absent=["python-ci-gate"],
                      flight=["pricing-artifact"])
        assert self.o.classify_pr(self._pr(), cr, False) == "running"
        # ...and it is not a reason list for anyone's dispatch either
        assert self.o.fix_ci_reasons(cr) == []

    def test_a_RED_fast_gate_is_work_even_beside_a_running_job(self):
        """⛔ THE DOMINANT LIVE SHAPE, AND A DEFECT IN THE FIRST CUT OF #1872 (found in review).

        `docs`/`legal-e2e`/`test-isolation`/`license-surface` fail long before the matrix
        finishes, so "a required check is RED while `python-ci-gate` is not yet created" is the
        NORMAL state of a PR with a failing fast gate. The `running` arm covers flight-or-
        not-yet-reported ONLY; without `not gated_red` every such PR read `running` for the rest
        of the suite and no lane ever repaired it."""
        cr = self._cr(red=["docs"], absent=["python-ci-gate"],
                      flight=["agent-infra-ci / lint"])
        assert self.o.classify_pr(self._pr(), cr, False) == "fix-ci"
        assert self.o.fix_ci_reasons(cr) == ["docs"]
        # the same red beside a REQUIRED check in flight is still work
        cr2 = self._cr(red=["docs"], flight=["python-ci-gate"])
        assert self.o.classify_pr(self._pr(), cr2, False) == "fix-ci"

    def test_a_partially_absent_head_with_nothing_in_flight_is_rerun_checks(self):
        """MEASURED LIVE, #8822 (2026-10-16). `python-ci-gate` was absent -- its gate job never
        got created -- while `drift-guard` was red, and NOTHING was still running. The two old
        arms sent this to `fix-ci` (the beat) and to `unreviewed` (the dispatcher's fork):
        re-triggering the missing job is the work, and it comes BEFORE any review."""
        cr = self._cr(red=["ai-review-gate"], absent=["python-ci-gate"])
        assert self.o.classify_pr(self._pr(), cr, False) == "rerun-checks"

    def test_the_four_live_disagreements_are_now_one_answer(self):
        """THE MEASUREMENT THIS CHANGE EXISTS FOR. On 2026-10-16, over the 11 open non-draft PRs,
        the beat's classifier and the dispatcher's fork disagreed on FOUR, while both looked
        correct. The shapes below are the actual evidence read at that moment (#8825, #8806,
        #8822, #8824); each is one PR, and each must now have exactly ONE answer."""
        cases = {
            # a red diff-bound gate + a suite still in flight
            "#8806": self._cr(red=["ai-review-gate"], absent=["python-ci-gate"],
                              flight=["test (a)", "test-slow (a)"]),
            # a red diff-bound gate + a rail gate red + the gate job never created
            "#8822": self._cr(red=["ai-review-gate"], absent=["python-ci-gate"],
                              extra_red=["drift-guard"]),
            # a red diff-bound gate + nine jobs in flight
            "#8824": self._cr(red=["ai-review-gate"], absent=["python-ci-gate"],
                              flight=["test (%s)" % c for c in "abcdefghi"]),
            # a red diff-bound gate + a required check mid-run
            "#8825": self._cr(red=["ai-review-gate"], absent=["python-ci-gate"],
                              flight=["pricing-artifact"]),
        }
        got = {n: self.o.classify_pr(self._pr(), cr, False) for n, cr in cases.items()}
        assert got == {"#8806": "running", "#8822": "rerun-checks",
                       "#8824": "running", "#8825": "running"}, got

    def test_ai_review_gate_has_its_own_action_not_a_fix_ci_entry(self):
        assert "ai-review-gate" not in self.o.fix_ci_reasons(self._cr(red=["ai-review-gate"]))

    def test_the_non_required_check_is_named_not_implicit(self):
        """Excluded EXPLICITLY, so it cannot re-enter if it is ever added to branch protection.

        ⛔ AND NOT FOR THE REASON ONCE WRITTEN HERE. `agent-infra-ci / lint` does NOT "fail by
        construction": measured 2026-10-11 (job 114560749590) it is a plain ruff gate that failed on
        "Found 6 errors. [*] 3 fixable with the `--fix` option" -- real, fixable lint errors, tracked
        by #5203. It is excluded only because it is NOT one of the 7 required contexts.

        The self-defeating guard (prints "gate is working correctly", then refuses the rail it
        mandates and fails the job) is `extensions/review-enforcer` -- agent-infra #6395 / #1203 --
        a DIFFERENT check. One name was doing duty for two artifacts.
        """
        assert "agent-infra-ci / lint" in self.o.NOT_REQUIRED_CHECKS
        assert not hasattr(self.o, "SELF_DEFEATING_CHECKS")   # the false framing is gone

    def test_classification_is_total_and_ordered(self):
        """Every PR yields EXACTLY ONE class, or None -- the partition cannot leak."""
        for ms in ("BLOCKED", "DIRTY", "UNSTABLE", "CLEAN"):
            for cr in (self._cr(), self._cr(red=["ai-review-gate"]),
                       self._cr(red=["python-ci-gate"]), self._cr(absent=self.REQ),
                       self._cr(absent=["python-ci-gate"]),
                       self._cr(red=["ai-review-gate"], flight=["docs"]),
                       self._cr(extra_red=["drive"])):
                for att in (True, False):
                    got = self.o.classify_pr(self._pr(ms=ms), cr, att)
                    assert got is None or got in self.o.CLASS_ORDER, got


# ── the RES: system-resources segment ─────────────────────────────────────────────────
# The failure this must not repeat: a prototype printed `pi processes=0` from a `pgrep`
# pattern that did not match -- a FALSE ZERO. Zero is a claim; an unread signal is UNKNOWN,
# and it must never be laundered into a confident band.
class TestResourceBands:

    def test_REQUIRED_matches_branch_protection_or_says_unknown(self):
        """`REQUIRED` is a HARDCODED tuple that equals branch protection only by coincidence of
        maintenance. Nothing pinned it, so a branch-protection change would silently re-break the
        DO-list filter in BOTH directions (omitting real work / advertising dead work).

        ⛔ AND AN UNREAD COMPARISON IS `skip`, NEVER A PASS. If `gh` cannot be reached we have NOT
        verified the set -- reporting a green here would be exactly the false all-clear this lane
        keeps removing. A skip is the honest `unknown`.
        """
        import json, subprocess
        o = self.o
        try:
            p = subprocess.run(["gh", "api",
                                "repos/{}/branches/main/protection".format(o.REPO),
                                "--jq", ".required_status_checks.contexts"],
                               capture_output=True, text=True, timeout=60)
        except Exception as e:
            import pytest; pytest.skip("gh unavailable: {}".format(e))
        if p.returncode != 0:
            import pytest; pytest.skip("branch protection unreadable: {}".format(p.stderr.strip()[:120]))
        try:
            live = set(json.loads(p.stdout))
        except Exception:
            import pytest; pytest.skip("unparsable branch protection payload")
        assert live == set(o.REQUIRED), (
            "REQUIRED has DRIFTED from branch protection.\n"
            "  only in REQUIRED (will advertise dead work): {}\n"
            "  only in protection (will omit real work):   {}".format(
                sorted(set(o.REQUIRED) - live), sorted(live - set(o.REQUIRED))))
        assert live, "an EMPTY protection context set is not a match"

    def test_load_advisory_four_branches_unread_is_never_free(self):
        """All three bands + the unread case. An UNREAD load must SAY SO and must never read as
        'dispatch freely' -- a failed read is not an empty success."""
        o = self.o
        assert "DO NOT DISPATCH" in o.load_advisory({"load": float(o.LOAD_REFUSE)})
        assert "DO NOT DISPATCH" in o.load_advisory({"load": 500.0})
        assert "ONE lane" in o.load_advisory({"load": float(o.LOAD_CAUTION)})
        assert "ONE lane" in o.load_advisory({"load": 51.0})
        assert "freely" in o.load_advisory({"load": 0.0})
        got = o.load_advisory({"load": None})
        assert got == "load=unread ADVISORY: unknown", got
        assert "freely" not in got

    def test_load_never_bands_and_never_steers_res_action(self):
        """REPORTED, not BANDED: `load` is absent from RES_REQUIRED, and a REFUSE-level load
        leaves the band untouched. The two signals are ALLOWED to disagree -- that is the design."""
        o = self.o
        assert "load" not in o.RES_REQUIRED
        r = dict(cores=10, cpu=5.0, runq=1, mem_used=50.0, pressure_free=80.0,
                 swap_act=0.0, top_name="x", top_pcpu=1.0)
        assert o.res_action(r) == "dispatch-many", o.res_action(r)
        assert o.res_action(dict(r, load=999.0)) == "dispatch-many"   # unchanged by load
        assert "DO NOT DISPATCH" in o.load_advisory(dict(r, load=999.0))
    @classmethod
    def setup_class(cls):
        cls.o = _objective_mod()
        cls.ok = {"cpu": 20, "runq": 2, "cores": 10, "mem_used": 40,
                  "pressure_free": 60, "swap": 10, "swap_act": 5,
                  "top_name": "pi", "top_pcpu": 5.0}

    def _r(self, **kw):
        d = dict(self.ok)
        d.update(kw)
        return d

    def test_any_unreadable_signal_is_UNKNOWN_never_a_band(self):
        for k in self.o.RES_REQUIRED:
            assert self.o.res_action(self._r(**{k: None})) == "UNKNOWN", k

    def test_unread_renders_UNKNOWN_never_a_zero(self):
        line = self.o.res_line(self._r(cpu=None, swap=None))
        assert "cpu=UNKNOWN%" in line and "swap=UNKNOWN%" in line
        assert line.endswith("| DO: UNKNOWN")

    def test_swap_used_alone_NEVER_forces_RECLAIM(self):
        """THE LATCH, PINNED WITH THE DEMONSTRATED READING. The gate held `DO: RECLAIM` on a box
        at cpu=71.3% runq=5/10 with swap=86.8%, withholding three genuinely idle lanes from a
        12-PR backlog. `swap used` is a HIGH-WATER MARK -- across eighteen consecutive beats it
        drifted 90.1 -> 86.8 (3.3 points) while cpu moved 30 and runq moved 74 -- so banding on
        it latches RECLAIM shut FOREVER, and a gate that can never open is not a gate."""
        r = self._r(cpu=71.3, runq=5, mem_used=94.4, pressure_free=68, swap=86.8, swap_act=12)
        assert self.o.res_action(r) == "dispatch-one"      # the gate OPENS

    def test_high_swap_ACTIVITY_still_forces_RECLAIM(self):
        """Do not weaken the gate -- correct the quantity it measures."""
        assert self.o.res_action(self._r(cpu=40, swap=86.8, swap_act=200)) == "RECLAIM"

    def test_genuine_saturation_still_forces_RECLAIM(self):
        assert self.o.res_action(self._r(runq=10, cores=10)) == "RECLAIM"   # queue saturates
        assert self.o.res_action(self._r(pressure_free=5)) == "RECLAIM"     # Apple says critical
        assert self.o.res_action(self._r(cpu=95)) == "RECLAIM"

    def test_swap_act_and_swap_used_both_appear(self):
        """`swap used` stays REPORTED (it is real) but no longer decides."""
        line = self.o.res_line(self._r(swap=86.8, swap_act=12))
        assert "swap=86.8%" in line and "swap-act=12pg/s" in line

    def test_bands_walk_down(self):
        assert self.o.res_action(self._r(cpu=95)) == "RECLAIM"
        assert self.o.res_action(self._r(cpu=80)) == "hold"
        assert self.o.res_action(self._r(runq=10, cores=10)) == "RECLAIM"
        assert self.o.res_action(self._r(cpu=60)) == "dispatch-one"
        assert self.o.res_action(self._r(cpu=30)) == "dispatch-many"

    def test_dispatch_many_needs_the_queue_and_swap_to_agree(self):
        """Low cpu is NOT a green light on its own."""
        assert self.o.res_action(self._r(cpu=30, swap_act=60)) == "RECLAIM"  # active thrashing

    def test_both_memory_signals_print_side_by_side(self):
        """Apple's verdict and the page arithmetic disagree by design -- show BOTH."""
        assert "mem=92.4%|58%free" in self.o.res_line(self._r(mem_used=92.4, pressure_free=58))

    def test_the_runaway_detector_is_rendered(self):
        assert "top=admin-merge.sh(98.2%)" in self.o.res_line(self._r(top_name="admin-merge.sh", top_pcpu=98.2))

    def test_res_age_is_on_the_line(self):
        """A resource reading is valid for SECONDS and this line AUTHORISES CONCURRENCY --
        so a stale read must be visible AS stale, not printed as current."""
        assert "res_age=0s" in self.o.res_line(self._r())

    def test_reclaim_suppresses_need_dispatch_and_says_why(self):
        """Two opposite imperatives on one line is worse than a missing line."""
        out = self.o.gate_dispatch("RECLAIM", "IDLE->2 need dispatch (see x) | ",
                                   "runq=79/10 swap=90.1%")
        assert "need dispatch" not in out
        assert "WITHHELD" in out and "runq=79/10" in out and "adding lanes makes it worse" in out
        assert out.startswith("[RES RECLAIM]")

    def test_hold_also_gates_because_it_also_means_add_nothing(self):
        assert "WITHHELD" in self.o.gate_dispatch("hold", "IDLE->2 need dispatch", "runq=12/10 swap=10%")

    def test_dispatch_bands_leave_the_lane_clause_alone(self):
        for act in ("dispatch-one", "dispatch-many"):
            assert self.o.gate_dispatch(act, "IDLE->2 need dispatch", "runq=1/10 swap=5%") \
                == "IDLE->2 need dispatch"

    def test_reclaim_with_no_dispatch_clause_is_untouched(self):
        assert self.o.gate_dispatch("RECLAIM", "land what exists", "runq=9/10") == "land what exists"

    def test_unread_still_never_renders_a_zero(self):
        line = self.o.res_line(self._r(cpu=None, runq=None, swap=None, mem_used=None))
        assert "cpu=UNKNOWN%" in line and "runq=UNKNOWN/" in line
        assert "mem=UNKNOWN%|" in line and "swap=UNKNOWN%" in line
        assert line.endswith("| DO: UNKNOWN")

    def test_the_SECOND_do_shape_also_inherits_the_gate(self):
        """THE REGRESSION, PINNED. The gate first matched the literal phrase 'need dispatch', so
        when the emitter switched to its second shape -- 'IDLE->hand the next unheld item' -- the
        gate silently stopped matching and FOUR lanes were offered while DO: RECLAIM said add
        nothing. A gate that a new emitter can evade by PHRASING is not a gate."""
        clause = ("IDLE->hand the next unheld item: Design partners website(2292m)[DE2BADBB] | "
                  "Merigng PR(2200m)[597F6D5A] | ")
        out = self.o.gate_dispatch("RECLAIM", clause, "runq=40/10 swap=89.7%")
        assert "hand the next unheld item" not in out      # the instruction is neutralised
        assert "WITHHELD" in out
        assert "runq=40/10" in out and "swap=89.7%" in out
        assert out.startswith("[RES RECLAIM]")
        assert self.o.is_dispatch_clause(clause) is True

    def test_UNKNOWN_also_withholds_dispatch(self):
        """'I cannot read the resources' must not authorise adding lanes."""
        assert "WITHHELD" in self.o.gate_dispatch("UNKNOWN", "IDLE->2 need dispatch", "runq=? swap=?%")

    def test_call_rail_names_its_prs_and_escalates(self):
        """A token that names an action but not its object is a report, not an instruction.
        And a token that repeats verbatim teaches the reader to skip it.

        ⛔ AND THE ESCALATION MUST STATE A FACT, NOT GIVE AN ORDER (#1872). It used to read
        "— land or say why", which is an instruction -- and it named work the automatic chain
        (`pr-doctor`) was already doing, so the beat was a second copy of a decision already
        made. What the monitor alone can see is that a LANDABLE PR has been landable for N
        beats and the chain still has not landed it.
        """
        import os
        f = self.o.STUCK_FILE
        try:
            for beat in (1, 2, 3):
                st = self.o._stuck_bump([7960, 7924])
                tok = self.o._class_token("call-rail", 2, [(7924, None), (7960, None)], st)
                assert "#7924" in tok and "#7960" in tok      # the WORK is named
                if beat == 1:
                    assert "STUCK" not in tok
                else:
                    assert f"STUCK {beat} beats" in tok
                    assert "pr-doctor has not landed it" in tok
                    assert "land or say why" not in tok      # state, never an order
        finally:
            if os.path.exists(f):
                os.remove(f)

    def test_every_dispatchable_token_names_its_object(self):
        for k in ("call-rail", "record-review", "resolve-conflict", "rerun-checks"):
            assert "#7959" in self.o._class_token(k, 1, [(7959, None)]), k
        # fix-ci is deliberately NOT named -- it is the one class needing no triage to act on.
        assert "#7959" not in self.o._class_token("fix-ci", 1, [(7959, None)])

    def test_a_fixable_failure_reads_as_IN_PROGRESS_not_blocked(self):
        """Owner: "having to fix things is a NATURAL PART of the CI process". `fix-ci` rendered a
        routine repair step as a wall; nothing in the system did the work. A PR whose next step
        is 'fix the failing test' has an owner and an action -- it is MOVING."""
        import importlib.util, pathlib, tempfile, os
        # exercise the real rendering path through build()'s aggregation shape
        cnt = {}
        for why in ("python-ci-gate", "python-ci-gate", "docs", "python-ci-gate,test (slow (b))"):
            for nm in why.split(","):
                cnt[nm] = cnt.get(nm, 0) + 1
        line = "IN-PROGRESS: fixing " + " ".join(
            f"{n}={c}" for n, c in sorted(cnt.items(), key=lambda kv: (-kv[1], kv[0])))
        assert "python-ci-gate=3" in line and "docs=1" in line and "test (slow (b))=1" in line
        assert "blocked" not in line.lower() and "not ready" not in line.lower()
        assert "fix-ci=" not in line        # the state-shaped token is gone

    def test_fix_ci_bucket_still_partitions(self):
        """The bucket is renamed in DISPLAY, not in the partition -- counts still sum.

        `running` is a SEVENTH class (#1872): a required check in flight is neither work nor a
        gap, and folding it into `fix-ci` (as this file did until 2026-10-16) told the fleet to
        fix a suite that was still executing. Every class must still be exactly one per PR.
        """
        assert "fix-ci" in self.o.CLASS_ORDER
        assert "running" in self.o.CLASS_ORDER
        assert set(self.o.CLASS_ORDER) == {"call-rail", "blocked-by-rail", "rerun-checks",
                                           "resolve-conflict", "record-review", "running",
                                           "fix-ci"}

    def test_a_MISSING_rail_gate_is_not_a_block(self):
        """THE #8009 PHANTOM. `blocked-by-rail(drift-guard)` was reported while that head
        carried EXACTLY ONE drift-guard check-run and it was `success` -- the GraphQL rollup
        had not returned it, and ABSENT was read as FAILING. Absence is equally satisfied by a
        green gate and by an incomplete read: opposite conclusions, so it proves nothing."""
        red, fl = set(), set()
        assert self.o.rail_block_reason(red, fl, set()) is None          # nothing seen -> no block
        assert self.o.rail_block_reason(set(), set(), set()) is None
        assert self.o.rail_block_reason({"drift-guard"}, set(), set()) == "drift-guard"   # RED does
        assert self.o.rail_block_reason(set(), {"provenance"}, set()) == "provenance"     # flight does


# ── a degraded snapshot is refused on EVERY path ──────────────────────────────
# ⛔ Review 2026-10-12: the refusal must hold on BOTH the `--stdin` and the invoke path, and these
# two tests exist so it cannot drift back into one branch.
#
# ⚠️ CORRECTED 2026-10-13 (found by review). This comment previously added a reason that was FALSE
# on both counts: "this refusal existed only inside the `--stdin` branch, so the default invoke path
# -- which is how heartbeat-loop.sh calls this tool -- accepted a degraded snapshot".
#   • `heartbeat-loop.sh:315` calls `/usr/bin/python3 "$SCRIPTS/lane-actions.py" --stdin "$SNAP"`,
#     i.e. the branch this comment called "the other path" is the one production actually uses.
#   • Neither call site predates this PR: `git show 42f0b14:scripts/lane-actions.py | grep -c
#     degraded` -> 0. Nothing was "left" unguarded; both arrived together.
# A reader who followed the old text would guard the wrong branch -- the exact failure that
# `_refuse_if_degraded`'s own docstring (lane-actions.py) says was already fixed. The TESTS were
# right; only the reason attached to them was wrong.

def test_a_degraded_snapshot_is_refused():
    rows = [{"lane": "a", "verdict": "WORKING"}, {"lane": "b", "degraded": True}]
    try:
        LA._refuse_if_degraded(rows, "test")
    except SystemExit as e:
        assert "REFUSING a DEGRADED snapshot" in str(e)
    else:
        raise AssertionError("a degraded row must refuse the whole snapshot")


def test_a_healthy_snapshot_is_not_refused():
    """The guard must not fire on a clean read, or it becomes the same false block in reverse."""
    rows = [{"lane": "a", "verdict": "WORKING", "degraded": False},
            {"lane": "b", "verdict": "WEDGED"}]
    LA._refuse_if_degraded(rows, "test")           # must not raise


def test_the_partial_guard_is_measured_against_the_live_roster(monkeypatch):
    """⛔ `want` was `len(_registry_labels())` -- the hand-written TSV -- while `registry()` had just
    become live-only. `16 >= 27 - REGISTRY_GRACE` is FALSE, so the guard called a HEALTHY snapshot
    PARTIAL and re-ran the whole scan with --no-cache on every pass, up to ~300s per tick, forever.

    Hermetic on purpose: an earlier version asserted `want > 0` ("the live roster must be readable on
    this box"), which made this test a property of the DEVELOPER'S MACHINE -- it fails wherever cmux
    is absent, i.e. in CI, which is exactly where it needs to run.
    """
    # `_live_workspaces` lives in lane-status, not here, so it is passed in as the module object
    # (which is how `load_snapshot` calls it) rather than monkeypatched onto this module.
    mod = type("M", (), {"_live_workspaces": staticmethod(lambda: [("ws1", {}), ("ws2", {})])})
    assert LA._live_want(mod) == 2, "want must come from the live roster"

    class Boom:
        @staticmethod
        def _live_workspaces():
            raise RuntimeError("cmux down")
    assert LA._live_want(Boom) is None, "an unreadable roster is UNKNOWN -- None, never 0"


def test_unknown_fleet_size_still_forces_a_re_scan(monkeypatch):
    """⛔ NONE IS NOT ZERO, PROVEN BEHAVIOURALLY. `_live_want` returned 0 on failure and the guard was
    `if not want or ...`, so an unreadable roster DISABLED the partial-snapshot guard entirely: a
    truncated snapshot was accepted on the FIRST attempt with no re-scan and no warning. "Guard
    disabled" and "guard needed" were the same event -- the fail-open direction, a partial fleet read
    published as a healthy one.

    ⛔ THIS TEST WAS A SOURCE-STRING ASSERTION on `if want is not None and ...`, which a reviewer
    correctly identified as pinning the literal TEXT rather than the behaviour: any semantically
    equivalent rewrite would pass while the fail-open returned. This drives the real invoke path
    with an unreadable roster and asserts the `--no-cache` re-scan actually happens -- under the old
    `if not want` polarity, `not 0` is True, attempt 0 returns, and this fails with exactly 1 run.
    """
    import subprocess as _sp

    calls = []

    class _R:
        stderr = ""
        returncode = 0

        def __init__(self, out):
            self.stdout = out

    def _run(*a, **k):
        calls.append(list(a[0]) if a and isinstance(a[0], list) else [])
        return _R(json.dumps([{"lane": "a", "verdict": "WORKING"}]))

    monkeypatch.setattr(_sp, "run", _run)
    monkeypatch.setattr(LA, "_live_want", lambda LS=None: None)   # roster UNREADABLE
    rows, _age, _ref = LA.load_snapshot(_Args(stdin=None))
    assert len(calls) == 2, (
        "an unreadable roster (None) must NOT satisfy the partial-snapshot guard -- expected the full "
        "cached pass plus a --no-cache re-scan, got %d run(s): %r" % (len(calls), calls))
    assert "--no-cache" in calls[1], "the re-scan must bypass the cache"
    assert rows, "a best-effort snapshot must still be returned after the re-scan"


def test_an_unreadable_roster_is_reported_as_unknown_not_zero():
    """The helper's own polarity, behaviourally: unreadable AND empty both mean UNKNOWN, never 0.
    This is what made `if not want` dangerous -- 0 reads as 'nothing is missing'."""
    class _Boom:
        @staticmethod
        def _live_workspaces():
            raise OSError("cmux down")

    class _Empty:
        @staticmethod
        def _live_workspaces():
            return []

    assert LA._live_want(LS=_Boom) is None, "an unreadable roster must be None (unknown)"
    assert LA._live_want(LS=_Empty) is None, "an EMPTY roster is unknown, not 0 -- 0 disables the guard"


# ── the refusal must be pinned at the CALL SITE, not the helper ────────────────
# ⛔ Review cycles 2 AND 3 both falsified the earlier claim that "these two tests exist so the refusal
# cannot drift back into one branch": they called `_refuse_if_degraded` DIRECTLY, so deleting either
# call site left the suite green. A test of a gate must fail when the gate is removed from the code
# path it protects -- these drive the real entry point on BOTH paths.

class _Args:
    def __init__(self, stdin=None, sample=12, budget=300):
        self.stdin, self.sample, self.budget = stdin, sample, budget


def _degraded_rows():
    return [{"lane": "a", "verdict": "WORKING"},
            {"lane": "b", "verdict": "WORKING", "degraded": True}]


def test_load_snapshot_refuses_a_degraded_stdin_snapshot(tmp_path):
    f = tmp_path / "snap.json"
    f.write_text(json.dumps(_degraded_rows()))
    try:
        LA.load_snapshot(_Args(stdin=str(f)))
    except SystemExit as e:
        assert "DEGRADED" in str(e), e
        return
    raise AssertionError("the --stdin path accepted a degraded snapshot")


def test_load_snapshot_refuses_a_degraded_invoke_path_snapshot(monkeypatch):
    """⛔ THE INVOKE PATH. `_refuse_if_degraded` is called there too, and until this test existed
    deleting that call kept the suite green -- the exact fail-open the guard exists to prevent."""
    import subprocess as _sp

    class _R:
        stdout = json.dumps(_degraded_rows())
        stderr = ""
        returncode = 0

    monkeypatch.setattr(_sp, "run", lambda *a, **k: _R())
    try:
        LA.load_snapshot(_Args(stdin=None))
    except SystemExit as e:
        assert "DEGRADED" in str(e), e
        return
    raise AssertionError("the invoke path accepted a degraded snapshot")


def test_load_snapshot_accepts_a_healthy_snapshot_on_both_paths(tmp_path, monkeypatch):
    """The guards must not become a false block: a clean snapshot still loads."""
    healthy = [{"lane": "a", "verdict": "WORKING", "degraded": False}]
    f = tmp_path / "snap.json"
    f.write_text(json.dumps(healthy))
    rows, _age, _ref = LA.load_snapshot(_Args(stdin=str(f)))
    assert rows == healthy

    import subprocess as _sp

    class _R:
        stdout = json.dumps(healthy)
        stderr = ""
        returncode = 0

    monkeypatch.setattr(_sp, "run", lambda *a, **k: _R())
    monkeypatch.setattr(LA, "_live_want", lambda LS=None: 1)
    rows, _age, _ref = LA.load_snapshot(_Args(stdin=None))
    assert rows == healthy


# ── an ACTION needs a CONFIDENT label ──────────────────────────────────────────
# ⛔ MEASURED 2026-10-12, `NEEDS-ACTION.md:27`: `- 3 Onboarding [CONTINUE 0.44] (2h58m)` became
# `say CONTINUE, not a new task`, typed at a lane inert for ~3h. The classifier was not missing and
# the resolution table was not wrong: `conf` was carried to the report and GATED NOWHERE, so a
# coin-flip label carried the same weight as a certain one.

def test_the_live_misfire_fixture_is_no_longer_an_instruction():
    """The exact line from NEEDS-ACTION.md:27, as a regression fixture."""
    assert LA.offerable("CONTINUE", 0.44) is False, \
        "CONTINUE at 0.44 confidence must NOT become an instruction -- it is a coin flip"


def test_a_confident_label_is_still_offerable():
    """The gate must not become a false block: a confident label keeps working."""
    assert LA.offerable("CONTINUE", 0.95) is True
    assert LA.offerable("DONE_READY", 0.7) is True, "the floor is inclusive"


def test_unknown_confidence_fails_closed():
    assert LA.offerable("CONTINUE", None) is False, \
        "an unread confidence is not a high one -- same polarity as every unclear read"


def test_waiting_on_the_owner_is_never_offered_continue():
    """⛔ BLOCKED_HUMAN is a live conversation with the owner. Telling that lane to CONTINUE does not
    interrupt work -- it corrupts the conversation the lane exists to hold. Confidence cannot buy
    it: this is a LABEL exclusion, checked before the confidence rule."""
    assert LA.offerable("BLOCKED_HUMAN", 0.99) is False
    assert LA.offerable("BLOCKED_HUMAN", 1.0) is False
    assert "BLOCKED_HUMAN" not in LA.OFFERABLE


def test_non_offerable_labels_are_never_instructions():
    for v in ("UNCLASSIFIED", "PROTECTED", "WORKING", "WAITING_ON_CHILD", "TOOL-IN-FLIGHT"):
        assert LA.offerable(v, 0.99) is False, "%s must never be an instruction" % v


# ── STEP 0: IDENTITY IS EVIDENCE, NOT A NAME LIST (owner, 2026-10-20) ────────────────────────
# ⛔ THE MEASURED DEFECT. Protection was `PROTECTED = ("DMeer", "DMer", "HANG")` matched by
# SUBSTRING against the lane's NAME. The owner's own workspace is titled **"Personal website"**, so
# it matched nothing: the roster classified it as an idle fleet lane and the PR doctor dispatched a
# tortoise PR brief INTO IT -- twice, reported by the owner. A name list protects the names someone
# remembered; every name it misses fails toward "idle: dispatch it".
#
# These tests are the inverted rule: a workspace is a FLEET lane only when its session cwd
# demonstrates a fleet worktree (or a harness spawn record names it), and EVERYTHING else is the
# owner's. They fail on the old implementation for the right reason -- it had no notion of a cwd.

def _build_with(rows, words="DONE_READY", live=None, markers=frozenset()):
    """`build()` with the words layer STUBBED, so the deterministic rules can be tested alone.

    ⛔ It answers EVERY lane that reaches Step 5 with the same confident label. That is the point:
    the words layer is allowed to be WRONG here, and the mechanical evidence still decides.
    """
    real = LA.jev_step5
    try:
        def fake(step5, LV, enabled=True):
            return ({c["lane"]: (words, 0.9) for c in step5},
                    {"source": "JEV", "error": None, "model": "stub",
                     "answered": len(step5), "asked": len(step5)})
        LA.jev_step5 = fake
        return LA.build(rows, FakeLS(), None, use_jev=True,
                        live=live if live is not None else set(),
                        spawn_markers=set(markers))
    finally:
        LA.jev_step5 = real


def test_the_legacy_name_union_matches_a_WORD_not_a_substring():
    """⛔ REVIEW ROUND 9 (P3): the union was a raw substring test, so a demonstrably-fleet lane whose
    title merely CONTAINS one of the names (`CHANGELOG sweep`, `SHANGHAI rollout` both contain
    `HANG`) was demoted to PROTECTED and vanished from LIST 1 -- the last name-based decision left in
    the classifier. A word match keeps what the names were remembered for and drops the accident."""
    assert LA._legacy_name_hit("DMeer - linkedin outreach") is True, "a decorated historical title"
    assert LA._legacy_name_hit("HANG") is True
    assert LA._legacy_name_hit("hang") is True, "titles are user-facing and get recased"
    assert LA._legacy_name_hit("CHANGELOG sweep") is False
    assert LA._legacy_name_hit("SHANGHAI rollout") is False
    assert LA._legacy_name_hit("dmeer2") is False, "a token that merely starts with the name"
    # a fleet lane whose title contains the substring stays a dispatch target
    lane = "CHANGELOG sweep"
    res = _build_with([row(lane=lane, sid="sid-ch", ws="WS-CH", cwd=fleet_wt(lane))])
    assert lane in res["dispatch_targets"], [c["why"] for c in res["report"]]
    # ...and a genuinely legacy-named fleet lane is still protected (the union still applies)
    res2 = _build_with([row(lane="DMer", sid="sid-dm", ws="WS-DM", cwd=fleet_wt("DMer"))])
    assert "DMer" not in res2["dispatch_targets"], res2["dispatch_targets"]


def test_an_owner_workspace_is_never_sent_to_the_words_layer():
    """⛔ THE PRIVACY HALF OF THE IDENTITY RULE (review round 7, P2, MEASURED). `build()` excludes
    PROTECTED lanes from the Step-5 call itself ("their text does not belong in a third-party API
    request"), and NOTHING pinned it: deleting `and not c["protected"]` left every suite green while
    the owner's own transcript text was sent to Jev. This records WHAT the call was given, which no
    existing stub does (they all answer `{c["lane"]: ... for c in step5}` and never look at `step5`).
    """
    asked = []
    real = LA.jev_step5
    try:
        def rec(step5, LV, enabled=True):
            asked.extend(c["lane"] for c in step5)
            return ({c["lane"]: ("DONE_READY", 0.9) for c in step5},
                    {"source": "JEV", "error": None, "model": "rec",
                     "answered": len(step5), "asked": len(step5)})
        LA.jev_step5 = rec
        res = LA.build([
            row(lane="Personal website", sid="sid-ow", ws="WS-OW",
                cwd="/Users/owner/Documents/Personal website"),
            row(lane="land-77", sid="sid-fl", ws="WS-FL", cwd=fleet_wt("land-77")),
        ], FakeLS(), None, use_jev=True, live=set(), spawn_markers=set())
    finally:
        LA.jev_step5 = real
    assert asked == ["land-77"], (
        "the owner's workspace text reached the third-party words layer: %r" % (asked,))
    # ...and the mechanism that keeps it out is the CLASSIFICATION, not the refusal path
    own = [c for c in res["report"] if c["lane"] == "Personal website"]
    assert own and own[0]["why"][0].startswith("PROTECTED lane"), (
        "a name-list mutant that merely REFUSES the lane later would satisfy a substring check; the "
        "report must say PROTECTED first: %r" % (own[0]["why"] if own else "dropped"))
    assert res["n_protected"] == 1, res["n_protected"]
    # non-vacuity: the fleet lane WAS asked, so `asked == ["land-77"]` above is not empty by accident
    assert "land-77" in res["dispatch_targets"], res["dispatch_targets"]


def test_the_owner_workspace_is_protected_and_never_offered_as_work():
    """The exact defect: "Personal website" is the owner's, and it was dispatched into twice."""
    lane = "Personal website"
    res = _build_with([row(lane=lane, sid="sid-ow", ws="WS-OW",
                           cwd="/Users/owner/Documents/Personal website")])
    assert lane not in res["dispatch_targets"], "the owner's workspace became a dispatch target"
    assert lane not in {c["lane"] for c in res["idle"]}
    rep = [c for c in res["report"] if c["lane"] == lane]
    assert rep, "a protected workspace must be REPORTED, not silently dropped"
    # ⛔ `startswith`, NOT `in` (review round 7, P2, MEASURED). The refusal sentence ALSO contains
    # the word PROTECTED ("NOT a dispatch target -- ... PROTECTED as the owner's own work"), so a
    # substring check passed under a mutant that replaced the identity mechanism with the RETIRED
    # name list: `dispatch_refusal()` tests `identity == "OWNER"` independently, so the lane stayed
    # out of LIST 1 while `n_protected` went to 0 and the owner's text reached the words layer. The
    # classification must LEAD the reason, and the counter must see it.
    assert rep[0]["why"][0].startswith("PROTECTED lane"), rep[0]["why"][0]
    assert res["n_protected"] == 1, res["n_protected"]
    assert "Personal website" in rep[0]["why"][0], (
        "the reason must carry the EVIDENCE (the cwd), not just the word PROTECTED")


def test_a_fleet_rooted_worktree_is_a_fleet_lane():
    """Non-vacuity for the test above: the SAME row, on a real worktree under a fleet root, is
    dispatchable. The path is BUILT (a directory with the `.git` FILE `git worktree add` writes),
    never cited from this machine."""
    lane = "land-1234"
    cwd = fleet_wt(lane)
    res = _build_with([row(lane=lane, sid="sid-wt", ws="WS-WT", cwd=cwd)])
    assert lane in res["dispatch_targets"], [c["why"] for c in res["report"]]
    assert LA._is_fleet_worktree(cwd) is True


def test_a_tmp_rooted_worktree_is_a_fleet_lane(tmp_path):
    """⛔ REVIEW ROUND 3 (P1), MEASURED. The first version anchored `wt-<slug>` to `$HOME` and
    `/tmp/cell-home` only -- a HOME WHITELIST, i.e. the same "list of places" the directive removed,
    one level up. The fleet's own recipe is `git worktree add /tmp/wt-<slug>`: real linked worktrees
    appeared in `state/pi-reap-worktrees.log` under `/tmp`, and under the whitelist EVERY ONE read as
    the owner's -- excluded from dispatch for ever, with a READABLE cwd, so not even the blind-fleet
    counter fired. The temp root is therefore a fleet root.

    ⛔ AND THE NAME IS NOT THE EVIDENCE (review round 4, P2): `/tmp` is world-writable, so the test
    builds the WORKTREE (a `.git` FILE) instead of asserting on a bare directory name -- and pins
    that a `wt-` directory with no git artifact is not a lane.
    """
    wt = tmp_path / "wt-9204"
    wt.mkdir()
    # the fixture root must be a fleet root for the anchor to apply at all
    roots = LA.FLEET_ROOTS
    try:
        LA.FLEET_ROOTS = roots + (str(tmp_path),)
        assert LA._is_fleet_worktree(str(wt)) is False, "a bare `wt-` directory is not a lane"
        (wt / ".git").write_text("gitdir: /x/.git/worktrees/wt-9204\n")
        assert LA._is_fleet_worktree(str(wt)) is True
        assert LA.lane_identity({"lane": "L", "cwd": str(wt)}, markers=set())[0] == "FLEET"
        # a subdirectory of the worktree is still the fleet's
        (wt / "scripts").mkdir()
        assert LA._is_fleet_worktree(str(wt / "scripts")) is True
        # ⛔ A SYMLINKED SUBDIRECTORY IS JUDGED BY WHERE IT REALLY IS (built here, not cited: the
        # earlier version of this test used `/tmp/wt-9204/scripts`, a real symlink on ONE machine)
        owner = tmp_path / "Personal website"
        owner.mkdir()
        (wt / "escape").symlink_to(owner)
        assert LA._is_fleet_worktree(str(wt / "escape")) is False, "resolution must follow the link"
        # the temp root does not swallow an owner project that happens to live under it
        assert LA._is_fleet_worktree(str(tmp_path / "Personal website")) is False
        assert LA._is_fleet_worktree(str(tmp_path / "someones-repo" / "wt-draft")) is False
        # a bare cell checkout is NOT a lane: dispatching into a cell's main checkout is the hub
        # discipline violation, and it is a stated boundary (docs/ops/fleet-liveness.md §2a)
        (tmp_path / "cell-ai" / ".git").mkdir(parents=True)
        assert LA._is_fleet_worktree(str(tmp_path / "cell-ai")) is False
    finally:
        LA.FLEET_ROOTS = roots


def test_a_real_worktree_in_a_fleet_root_is_still_not_a_lane_without_the_NAME(tmp_path):
    """⛔ THE ANCHORING CLAUSE WAS UNPINNED (review round 10, P2, MEASURED). Every "a `wt-` name inside
    someone's project is not a lane" fixture was a path that does not exist, so both assertions
    passed on the `_is_linked_worktree` arm alone: replacing the anchored test with `if True:` (accept
    ANY real linked worktree that is a direct child of a fleet root) left the whole suite green --
    fail-open on the owner's own work, because `git worktree add ~/tortoise-wip fix/x` would then be
    a FLEET lane and a dispatch target. The artifact is BUILT here, so the NAME is what is under test.
    """
    roots = LA.FLEET_ROOTS
    try:
        LA.FLEET_ROOTS = roots + (str(tmp_path),)
        for name in ("tortoise-wip", "someones-repo"):
            d = tmp_path / name
            d.mkdir()
            (d / ".git").write_text("gitdir: /x/.git/worktrees/%s\n" % name)
            assert LA._is_linked_worktree(str(d)) is True, "the artifact must be a real worktree"
            assert LA._is_fleet_worktree(str(d)) is False, (
                "a real worktree directly in a fleet root is the OWNER's unless it is named wt-*: %s"
                % name)
        deeper = tmp_path / "someones-repo2" / "wt-draft"
        deeper.mkdir(parents=True)
        (deeper / ".git").write_text("gitdir: /x/.git/worktrees/wt-draft\n")
        assert LA._is_fleet_worktree(str(deeper)) is False, (
            "the `wt-` anchor is the FIRST segment under a fleet root, not any segment")
    finally:
        LA.FLEET_ROOTS = roots


def test_a_git_FILE_alone_is_not_proof_of_a_worktree(tmp_path):
    """⛔ REVIEW ROUND 8 (P3): the docstrings presented `.git` as a FILE as *proof* of a linked
    worktree. It is not -- `git submodule` and `git init --separate-git-dir` write one too. What
    `git worktree add` writes is a pointer to `<main>/.git/worktrees/<name>`, so that is what is
    required; a submodule module dir or a custom git dir does not match."""
    base = tmp_path / "repo" / ".worktrees" / "x"
    base.mkdir(parents=True)
    for pointer in ("gitdir: /x/.git/modules/sub\n", "gitdir: /x/custom-gitdir\n", "junk\n"):
        (base / ".git").write_text(pointer)
        assert LA._is_linked_worktree(str(base)) is False, pointer
        assert LA._is_fleet_worktree(str(base)) is False, pointer
    (base / ".git").write_text("gitdir: /x/.git/worktrees/x\n")
    assert LA._is_linked_worktree(str(base)) is True
    assert LA._is_fleet_worktree(str(base)) is True


def test_a_plain_directory_named_worktrees_is_not_a_lane(tmp_path):
    """⛔ REVIEW ROUND 2 (P2), MEASURED: the `.worktrees` shape was accepted on its SPELLING, so
    `/x/.worktrees/b` -- a directory nobody's git ever made -- was a fleet lane, a dispatch target,
    and (through pr-doctor's adopt arm) somewhere `reset --hard` could run. A lane now has to be a
    REAL linked worktree: `.git` as a FILE, which is what `git worktree add` writes."""
    repo = tmp_path / "GitHub" / "tortoise"
    wt = repo / ".worktrees" / "prd-12"
    wt.mkdir(parents=True)
    assert LA._is_fleet_worktree(str(wt)) is False, "a bare directory is not a worktree"
    (wt / ".git").write_text("gitdir: /x/.git/worktrees/prd-12\n")
    assert LA._is_fleet_worktree(str(wt)) is True
    assert LA._is_fleet_worktree(str(wt / "scripts")) is True, (
        "a lane's session cwd is often a SUBDIRECTORY of its worktree")
    main_co = tmp_path / "checkout"
    (main_co / ".git").mkdir(parents=True)
    assert LA._is_fleet_worktree(str(main_co / ".worktrees" / "x")) is False, (
        "`.git` as a DIR is a main checkout, never a lane")


def test_an_owners_own_real_worktree_is_the_documented_boundary(tmp_path):
    """PIN THE BOUNDARY, DO NOT HIDE IT (review round 2, P3: the docstring cited a test that did
    not exist, and `pytest` never ran the `main()`-harness check it pointed at). An owner who runs
    `git worktree add` inside their own project produces a path this rule accepts. That is a
    residual, stated in the docstring and filed, not an accident -- if someone narrows it later,
    this test is where they must say so."""
    owner_wt = tmp_path / "Personal website" / ".worktrees" / "preview"
    owner_wt.mkdir(parents=True)
    (owner_wt / ".git").write_text("gitdir: /x/.git/worktrees/preview\n")
    assert LA._is_fleet_worktree(str(owner_wt)) is True, (
        "the boundary moved -- update the docstring and the filed issue, do not just flip this")


def test_identity_evidence_never_raises_on_a_poisoned_path():
    """⛔ REVIEW ROUND 2 (P3), MEASURED: `_real` caught only OSError, but `realpath` raises
    ValueError for an embedded NUL -- so one poisoned cwd killed the whole beat with a traceback
    instead of classifying that lane PROTECTED. Fail-closed must never mean fail-loud-on-one-row."""
    assert LA._is_fleet_worktree("/tmp/cell-home/wt-1\x00bad") is False
    assert LA.lane_identity({"lane": "L", "cwd": "/tmp/cell-home/wt-1\x00bad"},
                            markers=set())[0] == "OWNER"
    # unreadable is `None`, NOT a normalised spelling of the poisoned input: a path nobody could
    # resolve must not be allowed to decide its own classification by its own first segment
    assert LA._real("/tmp/cell-home/wt-1\x00bad") is None
    # the RESOLUTION is what is asserted, never the spelling: on macOS `/tmp` is a symlink to
    # `/private/tmp`, so comparing to the input string would fail on the very platform whose shape
    # `FLEET_ROOTS` names (review round 6, P3)
    _p9 = os.path.join(tempfile.gettempdir(), "wt-9")
    assert LA._real(_p9) == os.path.realpath(_p9)


def test_a_returned_dispatch_is_not_refused_for_the_tool_it_settled():
    """⛔ PYTEST-LEVEL PIN, because CI NEVER RUNS `main()` (review round 6, P3). The R5 fix
    (`r["tool_in_flight"] = False` on the RETURNED branch) was pinned only by two inline `check()`
    calls, which `python3.12 -m pytest scripts/test_lane_actions.py` does not collect -- measured,
    deleting the fix left pytest fully green. Same root as agent-infra#1692; this closes the hole for
    the behaviour without waiting for the harness to be collected.

    ⛔ AND THE ROW IS THE PRODUCTION STATE (review round 10, P2, MEASURED): `lane-status.py` calls an
    unmatched `task`/`subagent` call older than 600s with no spinner **`WAITING-OVERDUE`** -- its
    idle branch needs `last_stop == "stop"`, and the last record of an unmatched dispatch is the
    assistant message carrying the `toolCall`. The first version of this test hand-set
    `verdict="DONE-IDLE"` TOGETHER with a live `tool`, a combination lane-status never emits, so it
    passed while the production lane was still refused with "mechanical verdict WAITING-OVERDUE is
    not DONE-IDLE" printed directly under "the dispatch RETURNED". Both shapes are covered here.
    """
    ls = FakeLS(files={"sid-1": "/fake/parent.jsonl"}, recs=[rec_call("c1"), rec_result("c1")])
    for mech in ("DONE-IDLE", "WAITING-OVERDUE", "LONG-TOOL"):
        c = cls(row(verdict=mech, last="assistant",
                    tool={"name": "subagent", "age": 10200, "timeout": None}), LS=ls)
        assert c["tool_in_flight"] is False, (mech, c)
        assert c["dispatch_returned"] is True, (mech, c)
        assert "tool call is in flight" not in LA.dispatch_refusal(c), (mech, c["why"])
        assert "is not DONE-IDLE" not in LA.dispatch_refusal(c), (
            mech, LA.dispatch_refusal(c), c["why"])
    # ...and the disproof does NOT travel: an UNMATCHED dispatch on the same lane keeps its refusal
    cut = cls(row(verdict="WAITING-OVERDUE", last="assistant",
                  tool={"name": "subagent", "age": 10200, "timeout": None}),
              LS=FakeLS(files={"sid-1": "/fake/parent.jsonl"}, recs=[rec_call("c1")]))
    assert cut.get("dispatch_returned") is not True, cut
    assert LA.is_dispatch_target(cut) is False, LA.dispatch_refusal(cut)


def test_the_TEMP_ROOT_is_a_fleet_root_even_with_the_injected_fixture_active():
    """⛔ REVIEW ROUND 5 (P2): THE PRODUCTION ROOT LIST WAS UNPINNED. Every other `wt-` fixture
    resolves through the module-level injected fixture root (`_FLEET_WT_ROOT`, appended at import),
    so deleting the temp-root arm from `FLEET_ROOTS` -- exactly the round-3 regression
    (`git worktree add /tmp/wt-<slug>`, the fleet's own recipe) -- left the suite green. This test
    uses a directory under `tempfile.gettempdir()`, which the injected root cannot stand in for:
    it is NOT below `_FLEET_WT_ROOT`, so it can only pass through the temp-root arm. VERIFIED BY
    MUTATION: deleting `tempfile.gettempdir()` alone leaves the suite green (on Linux `/tmp` is still
    a root), but deleting ALL THREE temp-root arms (`tempfile.gettempdir()`, `/tmp`, `/private/tmp`)
    turns this test red and nothing else. The module-level injection is still in effect here, which is
    why this docstring says so instead of claiming a pristine list (rounds 6-7, P3).
    """
    d = tempfile.mkdtemp(prefix="wt-", dir=tempfile.gettempdir())     # /tmp/wt-xxxx
    try:
        assert LA._is_fleet_worktree(d) is False, "a name under /tmp is not evidence by itself"
        with open(os.path.join(d, ".git"), "w") as fh:
            fh.write("gitdir: /x/.git/worktrees/x\n")
        assert LA._is_fleet_worktree(d) is True, (
            "the temp root dropped out of FLEET_ROOTS: every real /tmp/wt-* lane is excluded again")
        assert LA.lane_identity({"lane": "L", "cwd": os.path.join(d, "sub")},
                                markers=set())[0] == "FLEET"
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_the_json_payload_carries_the_identity_counters(tmp_path, monkeypatch, capsys):
    """⛔ REVIEW ROUND 3 (P3). The counters exist so a MECHANICAL caller can tell "no lane is evidenced
    idle" from "identity evidence was lost, so every lane is PROTECTED". Published only in the human
    beat string, that distinction is unavailable to the caller `dispatch_targets` was added for --
    and the beat clause is suppressed whenever `idle` is non-empty. This pins the payload contract
    (`build`/`render_*` are stubbed: the VALUES are pinned by the build()-level tests)."""
    snap = tmp_path / "snap.json"
    snap.write_text(json.dumps([row(lane="L1", sid="s1", ws="W1"),
                                row(lane="L2", sid="s2", ws="W2")]))
    res = {"beat": "B", "meta": {}, "jev_down": False, "words_read": True,
           "idle": [], "wip": [], "wedged": [], "report": [], "quiet": [],
           "dispatch_targets": [], "n_protected": 2, "n_identity_unread": 2, "n_lanes": 2,
           "n_classified": 2}
    monkeypatch.setattr(LA, "build", lambda *a, **k: res)
    monkeypatch.setattr(LA, "render_md", lambda *a, **k: "md")
    monkeypatch.setattr(LA, "render_beat", lambda *a, **k: "B")
    monkeypatch.setattr(LA, "write_pair", lambda *a, **k: 0)
    argv = ["lane-actions.py", "--stdin", str(snap), "--json", "--out", str(tmp_path / "out.md")]
    sys.argv = argv            # main() parses sys.argv itself, by design
    rc = LA.main()
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["n_identity_unread"] == 2, payload
    assert payload["n_protected"] == 2, payload
    assert payload["n_classified"] == 2, payload
    assert payload["dispatch_targets"] == [], payload


def test_a_fleet_wide_loss_of_identity_does_not_read_as_a_quiet_fleet():
    """⛔ REVIEW ROUND 2 (P2). Identity is fail-closed, so when NO lane's cwd is readable every lane
    is PROTECTED, `idle` is empty, and the beat's first clause is NOTHING-ACTIONABLE -- the same line
    a genuinely quiet fleet produces. The instrument must say it is BLIND, not satisfied: otherwise
    the one surface the orchestrator reads reports "nothing to do" while the fleet cannot dispatch
    anything at all."""
    rows = [row(lane="L1", sid="s1", ws="W1", cwd=None), row(lane="L2", sid="s2", ws="W2", cwd=None)]
    res = _build_with(rows)
    assert res["dispatch_targets"] == [], res["dispatch_targets"]
    assert res["n_identity_unread"] == 2 and res["n_protected"] == 2, res
    line = LA.render_beat(res, "state/NEEDS-ACTION.md")
    assert "IDENTITY-UNREAD->2" in line and "NOT a quiet fleet" in line, line
    # and the SAME instrument, given a readable cwd for SOME lane, must not cry fleet-wide blind: a
    # partial loss is a plain PROTECTED count, because the dispatcher can still see part of the fleet
    res2 = _build_with([row(lane="L1", sid="s1", ws="W1", cwd=None),
                        row(lane="L2", sid="s2", ws="W2",
                            cwd="/Users/owner/Documents/Personal website")])
    assert res2["n_identity_unread"] == 1, res2
    assert res2["dispatch_targets"] == [], res2["dispatch_targets"]
    line2 = LA.render_beat(res2, "state/NEEDS-ACTION.md")
    assert "IDENTITY-UNREAD" not in line2, line2
    assert "PROTECTED->2" in line2, line2


def test_the_spawn_marker_reader_parses_the_harness_record(tmp_path):
    """The second demonstrable form of identity: `$O/bg/<name>.started`, written by
    `nonblocking-dispatch.sh` when it backgrounds a worker. Its `worktree=` line is the fleet's own
    record of a worktree it created."""
    bg = tmp_path / "bg"
    bg.mkdir()
    live_wt = tmp_path / "lanes" / "worker-7"
    live_wt.mkdir(parents=True)
    # a marker is evidence of a WORKTREE the harness created, so it must be one (review round 5, P2:
    # the writer validates only `[ -d ]`, and a marker naming `$HOME` would blanket every lane below)
    (live_wt / ".git").write_text("gitdir: /x/.git/worktrees/worker-7\n")
    (bg / "prd-7.started").write_text(
        "name=prd-7\nworktree=%s\nbranch=fix/x\nprompt=/tmp/p\n"
        "started=2026-10-20 10:00:00\ncap=2400s\n" % live_wt)
    (bg / "junk.started").write_text("name=junk\n")                 # no worktree= line
    (bg / "notes.txt").write_text("worktree=/should/not/count\n")    # not a marker file
    # ⛔ NOTHING REAPS `$O/bg/*.started` (review round 1, P3), so a marker outlives its worktree.
    # A marker whose directory is GONE is dropped: a path that no longer exists cannot be a lane
    # the fleet is running in, and keeping it would make this a stale list of paths -- the very
    # thing the owner's directive removes.
    (bg / "gone.started").write_text("name=gone\nworktree=%s\n" % (tmp_path / "lanes" / "dead"))
    marks = LA._spawn_marker_worktrees(str(bg))
    assert marks == {os.path.realpath(str(live_wt))}, marks
    assert str(tmp_path / "lanes" / "dead") not in marks, "a dead marker's path came back"
    # an absent directory is the NORMAL case (no background worker), never an error
    assert LA._spawn_marker_worktrees(str(tmp_path / "missing")) == set()
    # ⛔ AND A MARKER THAT NAMES A CONTAINER IS NOT EVIDENCE: a `.started` whose `worktree=` is `$HOME`
    # or the temp root would otherwise classify every workspace below it as the fleet's, permanently.
    for bad in (str(tmp_path), tempfile.gettempdir()):
        (bg / "bad.started").write_text("name=bad\nworktree=%s\n" % bad)
        got = LA._spawn_marker_worktrees(str(bg))
        assert bad not in got, ("a container marker became evidence: %s" % bad)
        assert LA.lane_identity({"lane": "Personal website",
                                 "cwd": str(tmp_path / "Personal website")},
                                markers=got)[0] == "OWNER", bad


def test_a_row_with_no_readable_cwd_is_protected():
    """FAIL-CLOSED: no cwd is not "idle lane", it is the absence of evidence."""
    lane = "unknown-cwd"
    res = _build_with([row(lane=lane, sid="sid-nc", ws="WS-NC")])     # no cwd at all
    assert lane not in res["dispatch_targets"]
    rep = [c for c in res["report"] if c["lane"] == lane]
    assert rep and "UNREADABLE" in rep[0]["why"][0], (rep[0]["why"] if rep else "dropped")
    # explicitly-None and empty-string cwds are the same fact, never a lane
    assert LA.lane_identity({"lane": lane, "cwd": None}, markers=set())[0] == "OWNER"
    assert LA.lane_identity({"lane": lane, "cwd": ""}, markers=set())[0] == "OWNER"


def test_working_tool_in_flight_child_and_unbound_are_never_dispatch_targets():
    """⛔ THE WORDS LAYER LIES HERE ON PURPOSE. Every row below is answered `DONE_READY` at 0.9,
    and every one of them is mechanically busy -- so a predicate that trusted the words would offer
    all of them. The decision tree ranks CPU > child > tool > words, so none may appear.
    """
    rows = [
        row(lane="working1", sid="sid-w1", ws="WS-A", cwd=fleet_cwd("working1", 201), cpu=True),
        row(lane="tool1", sid="sid-t1", ws="WS-A", cwd=fleet_cwd("tool1", 202),
            tool={"name": "bash", "age": 30, "timeout": None}),
        row(lane="child1", sid="sid-c1", ws="WS-A", cwd=fleet_cwd("child1", 203),
            verdict="WAITING-CHILD", child={"age": 60}, child_grew=True),
        row(lane="unbound1", sid=None, ws="WS-A", cwd=fleet_cwd("unbound1", 204)),
        row(lane="wedged1", sid="sid-wg1", ws="WS-A", cwd=fleet_cwd("wedged1", 205),
            verdict="WEDGED", spinner=True),
        row(lane="idle1", sid="sid-i1", ws="WS-A", cwd=fleet_cwd("idle1", 206)),
    ]
    res = _build_with(rows)
    assert res["dispatch_targets"] == ["idle1"], (
        "only the evidenced-idle lane may be a target, and the label was DONE_READY for ALL of "
        "them: %r" % (res["dispatch_targets"],))
    assert res["dispatch_targets"] == [c["lane"] for c in res["idle"]], (
        "dispatch_targets must be exactly the LIST 1 set -- two names for one list is the defect "
        "this field exists to prevent")
    # ⛔ WHERE EACH ONE LANDS IS PART OF THE CONTRACT. WORKING (Step 2) and a live child (Step 3)
    # need neither an action nor a report -- the tree already answered for them -- so they appear in
    # `quiet`. UNBOUND is REPORT ONLY, never actionable. WEDGED keeps its place in the unblock list
    # (it is a real candidate for a human) and must not be in the DISPATCH list.
    quiet = {c["lane"] for c in res["quiet"]}
    assert {"working1", "tool1", "child1"} <= quiet, sorted(quiet)
    reported = {c["lane"] for c in res["report"]}
    assert {"unbound1", "wedged1"} <= reported, sorted(reported)
    for lane in ("working1", "tool1", "child1", "unbound1", "wedged1"):
        assert lane not in res["dispatch_targets"], lane
    # and the reason a REPORTED lane was not offered names the failed clause. `wedged1` is the
    # sharpest case: its WORDS said DONE_READY at 0.9 while the mechanical verdict was WEDGED, so
    # the refusal must be the mechanical one -- the tree ranks it above the words.
    why_u = [c["why"][0] for c in res["report"] if c["lane"] == "unbound1"]
    assert why_u and "no session binding" in why_u[0], why_u
    why_w = [c["why"][0] for c in res["report"] if c["lane"] == "wedged1"]
    assert why_w and "WEDGED" in why_w[0] and "DONE-IDLE" in why_w[0], why_w


def test_is_dispatch_target_requires_a_completed_turn():
    """A quiet lane whose last record is a TOOL CALL is mid-turn, not idle."""
    c = cls(row(last="tool"))
    c["protected"], c["identity"], c["busy"] = False, "FLEET", False
    c["verdict"], c["conf"] = "DONE_READY", 0.9
    assert LA.is_dispatch_target(c) is False
    assert "COMPLETE" in LA.dispatch_refusal(c), LA.dispatch_refusal(c)


def test_identity_is_not_decided_by_a_name_list():
    """⛔ WIRING PIN, the same shape as `test_the_bucket_loop_actually_calls_the_gate`.

    The defect was `c["protected"] = any(p in c["lane"] for p in PROTECTED)` -- a SUBSTRING match
    on the lane NAME. Restoring that line restores the defect, because "Personal website" matches
    none of `("DMeer", "DMer", "HANG")`. The behavioural tests above cover the outcome; this pins
    that the MECHANISM is the evidence rule, so a future edit cannot quietly reintroduce a list.
    """
    src = open(os.path.join(HERE, "lane-actions.py"), encoding="utf-8").read()
    assert 'c["protected"] = any(p in c["lane"] for p in PROTECTED)' not in src, (
        "protection is decided by a name-list substring match again")
    assert "lane_identity(" in src, "build() must classify identity through lane_identity()"
    assert "_is_fleet_worktree(" in src
    # the historical tuple may only exist as the ADDITIONAL union, never as `PROTECTED`
    assert "PROTECTED_LEGACY_NAMES" in src
    # ⚠️ COMMENTS ARE EXCLUDED FROM THIS ONE. The comment block documenting the defect QUOTES
    # `PROTECTED = ("DMeer", "DMer", "HANG")`, and a substring test over the whole file therefore
    # failed on the file that had already been fixed -- a check that cannot tell code from the
    # record of the bug would forbid explaining it.
    code = [ln for ln in src.splitlines()
            if ln.strip() and not ln.lstrip().startswith("#")]
    assert not any(ln.startswith("PROTECTED = (") for ln in code), (
        "a tuple named PROTECTED is the retired mechanism -- keep it named PROTECTED_LEGACY_NAMES "
        "so a reader can see it is a union, not the rule")


def test_the_bucket_loop_actually_calls_the_gate():
    """⛔ WIRING PIN, DELIBERATELY A SOURCE ASSERTION. `build()` is not drivable under test (it reads
    cmux state, cpu maps and the transcript files), so nothing else can see whether the floor is
    applied at the DECISION. This pins that one call site and nothing else; the behaviour is covered
    by the tests above. Removing this call is how the floor becomes decorative."""
    src = open(os.path.join(HERE, "lane-actions.py"), encoding="utf-8").read()
    assert "if v in OFFERABLE and not offerable(v, c.get(\"conf\")):" in src, \
        "the bucket loop must consult offerable() -- otherwise low-confidence labels still reach wip"


# ⛔ NOTE ON WHERE THIS IS ACTUALLY CAUGHT. A synthetic pytest test calling `build()` with
# hand-written DEAD / CHILD-OVERDUE rows does NOT exercise this path -- build() re-classifies the
# rows itself, so such a test stayed green with the crash present (measured). The regression is
# caught by THIS FILE'S OWN `main()` harness, which drives build() with the real shipped fixtures:
#   /usr/bin/python3 scripts/test_lane_actions.py   -> ALL PASS with the fix,
#                                                      KeyError: 'conf' without it.
# That harness is not collected by pytest, which is the gap filed as agent-infra#1692.
def test_a_mechanical_label_is_offerable_without_a_confidence():
    """⛔ DEAD (Step 1) and CHILD-OVERDUE (Step 6) are MECHANICAL -- their evidence is the process
    table and the child record. They carry no `conf`, and requiring one was a reproduced crash."""
    assert LA.offerable("DEAD", None) is True
    assert LA.offerable("CHILD-OVERDUE", None) is True


# ── IDLE is reachable ONLY through Step 2 (#1867) ──────────────────────────────────────────────
# ⛔ MEASURED 2026-10-16 20:47Z, on the beat's own output:
#   `CAPACITY: 1 lane(s) idle >=20m with NO child in flight -- hand each the next unheld item`
#     -- `cmux cloud  DONE_READY  "no session write for 13h34m, no spinner contradiction"`
# Three independent reads said otherwise in the same minute: the pane showed an ACTIVE spinner, the
# lane's `ps -o time` moved +4.93s over 25s (838:22.16 -> 838:27.09), and its transcript mtime was
# current. `lane_cpu_busy()` had answered None -- not False -- because a live `task` CHILD is a second
# pi with the same cwd, so the strict "exactly one lane <-> exactly one pid" rule excluded it. Step 2
# was therefore skipped, and the verdict came from the transcript mtime alone.
# Following that line would have injected a second work order into a lane at 85% context, mid-turn.

def test_unattributed_progress_can_never_become_free_capacity():
    """A lane with proven progress in its OWN directory that the strict read cannot attribute to a
    single pid must not reach the words layer at all -- that is where `DONE_READY` came from."""
    c = cls(row(cpu=None, cpu_any=True, stale_s=48840, verdict="DONE-IDLE"))
    assert c["step"] == "2", "an idle-family claim must not be built past Step 2 (%r)" % (c["step"],)
    assert c["verdict"] == "UNATTRIBUTED-WORKING"
    assert c["action"] == "report", "report only: no dispatch, no unblock"


def test_proven_cpu_progress_outranks_an_unconfirmed_binding():
    """⛔ STEP 2 IS ABOUT THE LANE, NOT ABOUT THE SESSION FILE. `cpu is True` means the lane's own
    directory holds exactly one lane and a pi that consumed CPU in the window -- evidence a stale
    pane record cannot contradict. Reporting it as UNVERIFIED-SESSION would bury the fact that the
    lane is demonstrably working, and (before this change) let it fall through to the words layer."""
    c = cls(row(cpu=True, session_verified=False))
    assert (c["verdict"], c["step"], c["action"]) == ("WORKING", "2", None), c


def test_the_cpu_veto_is_consulted_at_the_decision_not_only_in_a_comment():
    """⛔ WIRING, ASSERTED THROUGH `build()` -- NOT THROUGH THE SOURCE TEXT. The bucket loop routes a
    STEP-2 verdict to `quiet`, so a Step-2 verdict that must be SEEN has to be exempted there, and
    that exemption is the difference between `UNATTRIBUTED-WORKING` being reported and being
    silently dropped. A source-substring assertion (the first version of this leg) survived the
    routing being removed whenever the same text remained anywhere in the file -- a comment
    included -- and went red on any reformat, so it pinned spelling, not behaviour (#1867 review)."""
    res = LA.build([row(lane="ua2", cpu=None, cpu_any=True, stale_s=48840, verdict="DONE-IDLE")],
                   FakeLS(files={"sid-1": "/x/s.jsonl"}), None, use_jev=False, live={"WS-1"})
    assert [c["lane"] for c in res["report"]] == ["ua2"], \
        "a report-only Step-2 verdict must be REPORTED, not routed to quiet (%r)" % (res,)
    assert "ua2" not in {c["lane"] for c in res["quiet"]}
# ── THE THIRD CONSUMER OF THE SAME CLASS VOCABULARY (#1872 review round 10) ─────────────────
# `pr-loop.py` reads `objective.CLASS_ORDER` and turns each class into an ACTION. `objective.py`
# and `pr-doctor.py` gained a `running` class; without an arm here the class fell through to the
# `ask-user` default below and a lane that is merely WAITING was reported as an owner decision.
# A pure `decide()` is testable without cmux, so it is tested rather than trusted.

def _prloop():
    return load("pr_loop", os.path.join(HERE, "pr-loop.py"))


def test_every_objective_class_maps_to_a_real_action_and_running_WAITS():
    """⛔ A CLASS WITH NO ARM IS NOT A NO-OP — it becomes `ask-user` (an owner decision)."""
    loop = _prloop()
    o = _objective_mod()
    actions = {"wait", "rail", "rerun", "fix", "review", "ask-user"}
    for klass in o.CLASS_ORDER:
        action, _detail = loop.decide(klass, "why")
        assert action in actions, (klass, action)
        # the ONLY classes that may become `ask-user` are the ones with no arm at all; every
        # class the classifier can emit must have one.
        assert action != "ask-user", (
            f"{klass} has no arm in pr-loop.decide() -- it would be reported to the owner as a "
            "human decision")
    assert loop.decide("running", None) == ("wait", None)


def test_a_waiting_pr_is_never_dispatched_or_asked_about(monkeypatch, capsys):
    """⛔ `wait` MUST SHORT-CIRCUIT BEFORE THE DISPATCH (and before the idempotence log, which is
    about work in flight rather than about a lane that is merely executing)."""
    loop = _prloop()
    o = _objective_mod()
    out = []
    monkeypatch.setattr(loop, "load_lanes", lambda: {})
    monkeypatch.setattr(loop, "save_lanes", lambda lanes: None)
    monkeypatch.setattr(loop, "log", out.append)
    monkeypatch.setattr(loop, "lane_live", lambda lane: True)
    monkeypatch.setattr(loop, "decide", loop.decide)
    monkeypatch.setattr(loop, "argparse", loop.argparse)
    # ⛔ THE FAKE STANDS IN FOR THE WHOLE MODULE, SO IT MUST PRESENT THE MODULE'S SURFACE (#1918).
    # `pr-loop.py` consults `o._class_counts_are_a_clearance(...)` before dispatching (a queue
    # whose CLASS counts are not a clearance dispatches nothing). A stand-in missing that attribute
    # is not "a readable queue" -- it is an `AttributeError` inside `main()`, which this test
    # caught when #1918 and this file first met. The REAL predicates are borrowed from the loaded
    # module, never re-implemented: a second threshold in a stub would be a second definition of
    # "blind" wearing a test's clothes. Both are presented because the clearance question
    # DELEGATES to the blindness one (#1942 review A/P2).
    monkeypatch.setattr(loop, "_objective", lambda: type("O", (), {
        "CLASS_ORDER": o.CLASS_ORDER,
        "resources": staticmethod(lambda: {}),
        "res_action": staticmethod(lambda r: "dispatch-one"),
        "_queue_read_is_blind": staticmethod(o._queue_read_is_blind),
        "_class_counts_are_a_clearance": staticmethod(o._class_counts_are_a_clearance),
        # `source` is `queue()`'s provenance key; `pr-loop.py` passes it through so a REST sample
        # is not read as blind (#2138). A fixture that omitted it would be defaulted here and
        # would stop exercising the call shape the dispatcher actually makes.
        "queue": staticmethod(lambda: {"nondraft": 1, "source": "graphql",
                                       "classes": {"running": 1},
                                       "by_class": {"running": [(4242, None)]}}),
    })())
    monkeypatch.setattr(sys, "argv", ["pr-loop.py"])
    assert loop.main() == 0
    joined = "\n".join(out)
    assert "4242" not in joined, joined
    assert "ASK-USER" not in joined, joined
    # a LINE PREFIX, not a substring: `ACT`/`DRY` appear inside ordinary words, and a test that
    # forbids them anywhere would fail the first time a log line mentions one.
    assert not [ln for ln in joined.splitlines() if ln.startswith(("DRY ", "ACT "))], joined


# ── THE LANE READ MUST FINISH INSIDE ITS CALLER'S PATIENCE (2026-10-18, measured) ──────────
# `pr-doctor.py` allowed this tool 600s while `load_snapshot` handed EACH of its two attempts the
# tool's full 300s. A real `--no-cache` scan measured 147s on a quiet box (this module's own note
# records 250-300s under load), so the escalate path summed to ~294s+ against a 300s inner bound
# and BEYOND the outer one: the pass died with `TimeoutExpired` and pr-doctor refused with rc 2.
# MEASURED, and stated narrowly because the loose version was false: the SCHEDULED path (`$STATE/pr-doctor.launchd.log`, first line 2026-10-10T22:49 -> last 2026-10-18T21:32) managed TWO dispatches ever -- 382 passes, 320 `LANE READ FAILED`, 241 of them `TimeoutExpired`. ⚠️ NOT `0 dispatches for six days`: the heartbeat's own launcher (`$STATE/pr-doctor.log`) carried the fleet intermittently (87 passes with `dispatched >0`).
# Figures are dated -- re-measure, do not quote.

def test_the_two_scan_attempts_share_ONE_budget(monkeypatch):
    """The bounds must COMPOSE. A fresh `budget` per attempt is what outlived the caller."""
    import subprocess as _sp

    budget = 100.0
    clock = {"t": 1000.0}
    monkeypatch.setattr(LA.time, "monotonic", lambda: clock["t"])
    seen = []

    class _R:
        stderr = ""
        returncode = 0

        def __init__(self, out):
            self.stdout = out

    def _run(*a, **k):
        seen.append(k.get("timeout"))
        clock["t"] += 60.0          # this scan burned 60s of the SHARED budget
        return _R(json.dumps([{"lane": "a", "verdict": "WORKING"}]))

    monkeypatch.setattr(_sp, "run", _run)
    monkeypatch.setattr(LA, "_live_want", lambda LS=None: None)   # unknown fleet size -> re-scan
    LA.load_snapshot(_Args(stdin=None, budget=budget))

    assert len(seen) == 2, seen
    # Attempt 0 takes a bounded SLICE (40%), so the retry that exists to FIX it is never starved
    # by it (#1788/#1774); the retry then gets the remainder of the same deadline, never a fresh
    # budget.
    assert abs(seen[0] - 0.4 * budget) < 0.01, seen
    assert abs(seen[1] - (budget - 60.0)) < 0.01, (
        "the re-scan must get the REMAINING budget, not a fresh one -- got %r" % (seen,))
    assert seen[0] + seen[1] <= budget + 0.01, (
        "the two attempts must fit inside ONE budget: %r" % (seen,))


def test_a_failed_rescan_does_not_discard_the_roster_already_read(monkeypatch, capsys):
    """⛔ AN UNREADABLE RETRY MUST NOT INVALIDATE A READABLE DATUM.

    The old code let the retry's exception propagate, so a non-degraded roster that lane-status HAD
    just read (i.e. a real cmux read) was thrown away because the second read of the same data
    timed out. `pr-doctor` then had no roster and refused. The escalation is a completeness
    IMPROVEMENT on `first`, never a precondition for using it.
    """
    import subprocess as _sp

    healthy = [{"lane": "a", "verdict": "WORKING", "degraded": False}]
    calls = []

    class _R:
        stderr = ""
        returncode = 0

        def __init__(self, out):
            self.stdout = out

    def _run(cmd, **k):
        calls.append(list(cmd))
        if len(calls) == 1:
            return _R(json.dumps(healthy))
        raise _sp.TimeoutExpired(cmd, k.get("timeout") or 0)

    monkeypatch.setattr(_sp, "run", _run)
    monkeypatch.setattr(LA, "_live_want", lambda LS=None: None)
    rows, _age, _ref = LA.load_snapshot(_Args(stdin=None))

    assert rows == healthy, "the readable roster must survive a failed re-scan"
    assert len(calls) == 2 and "--no-cache" in calls[1], calls
    err = capsys.readouterr().err
    assert "re-scan did not produce a usable read" in err, err
    assert "COMPLETENESS UNMEASURED" in err, err


def test_a_degraded_roster_is_still_REFUSED_with_no_fallback(monkeypatch):
    """The fallback above must not become a way to act on a DEGRADED (TSV-only) snapshot.

    `first` is only kept after `_refuse_if_degraded`, so a degraded attempt 0 still raises -- this
    pins that ordering, because moving the fallback above the guard would silently reopen the
    fail-open the DEGRADED_MSG refusal exists to close.
    """
    import subprocess as _sp

    class _R:
        stderr = ""
        returncode = 0

        def __init__(self, out):
            self.stdout = out

    def _run(*a, **k):
        return _R(json.dumps(_degraded_rows()))

    monkeypatch.setattr(_sp, "run", _run)
    monkeypatch.setattr(LA, "_live_want", lambda LS=None: None)
    try:
        LA.load_snapshot(_Args(stdin=None))
    except SystemExit as e:
        assert "DEGRADED" in str(e), e
        return
    raise AssertionError("a degraded roster was accepted via the re-scan fallback")



def test_a_SUCCESSFUL_rescan_wins_over_the_first_read(monkeypatch):
    """⛔ A BETTER READ MUST BE THE ONE RETURNED (2026-10-18, review).

    The fallback path kept only attempt 0 (`first`), so a retry that SUCCEEDED and returned MORE
    lanes was discarded whenever it still fell short of the roster estimate -- the caller kept the
    worse roster and was never told. `best` tracks the newest successful read; it always supersedes.
    """
    import subprocess as _sp

    seen = []

    class _R:
        stderr = ""
        returncode = 0

        def __init__(self, out):
            self.stdout = out

    def _run(*a, **k):
        seen.append(list(a[0]) if a else list(k.get("args") or []))
        rows = ([{"lane": "a"}] if len(seen) == 1
                else [{"lane": "a"}, {"lane": "b"}, {"lane": "c"}])
        return _R(json.dumps(rows))

    monkeypatch.setattr(_sp, "run", _run)
    # `want` is reachable by NEITHER read, so neither is "complete" and the function must fall
    # through to its strongest-read return.
    monkeypatch.setattr(LA, "_live_want", lambda LS=None: 99)
    rows, _age, _ref = LA.load_snapshot(_Args(stdin=None, budget=600.0))
    assert [r["lane"] for r in rows] == ["a", "b", "c"], (
        "the successful re-scan must be returned, not the shorter first read: %r" % (rows,))


def test_a_DEGRADED_rescan_does_not_discard_the_roster_already_read(monkeypatch, capsys):
    """⛔ `SystemExit` IS NOT AN `Exception` (2026-10-18, review).

    `_refuse_if_degraded` raises `SystemExit`, so the `except Exception` fallback missed it: a
    DEGRADED re-scan escaped and threw away a non-degraded roster attempt 0 had just read. The
    suite missed it because the sibling test fails the retry with `TimeoutExpired` (an ordinary
    `Exception`). This is the production shape of the bug: the retry is degraded, attempt 0 is not.
    """
    import subprocess as _sp

    healthy = [{"lane": "a", "verdict": "WORKING", "degraded": False}]
    degraded = [{"lane": "a", "verdict": "WORKING", "degraded": True}]
    calls = []

    class _R:
        stderr = ""
        returncode = 0

        def __init__(self, out):
            self.stdout = out

    def _run(cmd, **k):
        calls.append(list(cmd))
        return _R(json.dumps(healthy if len(calls) == 1 else degraded))

    monkeypatch.setattr(_sp, "run", _run)
    monkeypatch.setattr(LA, "_live_want", lambda LS=None: 99)   # neither read is "complete"
    rows, _age, _ref = LA.load_snapshot(_Args(stdin=None))

    assert rows == healthy, (
        "a DEGRADED re-scan must not discard the non-degraded roster already read: %r" % (rows,))
    assert len(calls) == 2 and "--no-cache" in calls[1], calls
    err = capsys.readouterr().err
    assert "COMPLETENESS UNMEASURED" in err, err


def test_a_degraded_FIRST_read_is_still_a_hard_REFUSAL(monkeypatch):
    """The fallback must not weaken the primary rule: with nothing already read, DEGRADED refuses."""
    import subprocess as _sp

    class _R:
        stderr = ""
        returncode = 0

        def __init__(self, out):
            self.stdout = out

    monkeypatch.setattr(_sp, "run",
                        lambda cmd, **k: _R(json.dumps([{"lane": "a", "degraded": True}])))
    monkeypatch.setattr(LA, "_live_want", lambda LS=None: 99)
    try:
        LA.load_snapshot(_Args(stdin=None))
    except SystemExit as e:
        assert "DEGRADED" in str(e), e
        return
    raise AssertionError("a degraded FIRST read must still refuse")
