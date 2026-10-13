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
import json
import os
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
        files[r["sid"]] = os.path.join(AGENT, "state", "sessions",
                                        "--x-repo-%s--" % r["lane"], "s.jsonl")
    # every lane but dead1 has a live process in its session dir; wait1 also wrote recently, which on
    # its own settles existence (a dead process does not write a transcript).
    cwds = dict((str(i), "/x/repo-%s" % r["lane"])
                for i, r in enumerate(rows) if r["lane"] != "dead1")
    fs = FakeLS(files=files, cwds=cwds, cpus=dict(cwds))
    for r in rows:
        if r["lane"] == "wait1":
            r["stale_s"] = 60
    # `live` is pinned so this test does not depend on whatever cmux happens to have running: all
    # rows here carry the default ws="WS-1", and they must all stay live/actionable.
    res = LA.build(rows, fs, None, use_jev=False, live={"WS-1"})
    got = {c["lane"]: c for c in res["idle"] + res["wip"] + res["wedged"] + res["report"] + res["quiet"]}
    check("every lane lands in exactly one bucket", len(got) == len(rows),
          "%d vs %d" % (len(got), len(rows)))
    check("partition invariant: bucket sizes sum to the fleet",
          sum(len(res[k]) for k in ("idle", "wip", "wedged", "report", "quiet")) == len(rows))
    check("WORKING lane is in neither action list nor report",
          "work1" not in {c["lane"] for c in res["idle"] + res["wip"] + res["wedged"] + res["report"]})
    check("waiting-on-child lane needs nothing", "wait1" in {c["lane"] for c in res["quiet"]})
    check("no such process -> DEAD in the unblock list",
          "dead1" in {c["lane"] for c in res["wedged"]})
    check("words layer unread -> nothing is guessed into an action list",
          not res["idle"] and not res["wip"] and not res["words_read"])
    check("words layer unread -> the Step-5 lanes are REPORTED, not dropped",
          {"idle1", "busy1", "prot1"} <= {c["lane"] for c in res["report"]})
    check("JEV-DOWN is announced", "JEV-DOWN" in LA.render_beat(res, "state/NEEDS-ACTION.md"))
    # PROTECTED and BUSY suppression
    res2 = LA.build([row(lane="DMeer - linkedin outreach", sid="sid-p")], FakeLS(),
                    None, use_jev=False)
    check("PROTECTED lane is never offered as work", not res2["idle"] and len(res2["report"]) == 1)
    check("PROTECTED reason is stated",
          "PROTECTED" in res2["report"][0]["why"][0], res2["report"][0]["why"])

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
        files_fc = dict((r["sid"], os.path.join(AGENT, "state", "sessions",
                                                "--x-repo-%s--" % r["lane"], "s.jsonl"))
                        for r in rows_fc)
        cwds_fc = dict((str(i), "/x/repo-%s" % r["lane"]) for i, r in enumerate(rows_fc))
        res_fc = LA.build(rows_fc, FakeLS(files=files_fc, cwds=cwds_fc, cpus=dict(cwds_fc)),
                          None, use_jev=False, live={"WS-1"})
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
    _files_f = dict((r["sid"], os.path.join(AGENT, "state", "sessions",
                                             "--x-repo-%s--" % r["lane"], "s.jsonl")) for r in rows_f)
    _cwds_f = {"0": "/x/repo-decoy"}
    fs_f = FakeLS(files=_files_f, cwds=_cwds_f, cpus=dict(_cwds_f))
    resf = LA.build(rows_f, fs_f, None, use_jev=False, live={"WS-LIVE"})
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
    _files_c = dict((r["sid"], os.path.join(AGENT, "state", "sessions",
                                             "--x-repo-%s--" % r["lane"], "s.jsonl")) for r in rows_c)
    _cwds_c = {"0": "/x/repo-decoyc", "1": "/x/repo-overdue1", "2": "/x/repo-stuck1"}
    fs_c = FakeLS(files=_files_c, cwds=_cwds_c, cpus=dict(_cwds_c))
    resc = LA.build(rows_c, fs_c, None, use_jev=False, live={"WS-C"})
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
    _files_n = dict((r["sid"], os.path.join(AGENT, "state", "sessions",
                                            "--x-repo-%s--" % r["lane"], "s.jsonl")) for r in rows_n)
    fs_n = FakeLS(files=_files_n, cwds={"0": "/x/repo-decoy"}, cpus={"0": "/x/repo-decoy"})
    resn = LA.build(rows_n, fs_n, None, use_jev=False,
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
    resu = LA.build(rows_n, fs_n, None, use_jev=False, live={"WS-RENAMED": "", "WS-SAME": ""})
    act_u = {c["lane"] for c in resu["idle"] + resu["wip"] + resu["wedged"]}
    check("H4: an UNKNOWN title filters nothing (fail-open on a legacy list)",
          "land-6260" in act_u and "land-lane-3" in act_u)

    # POLARITY: an unreadable workspace list must filter NOTHING, so a cmux hiccup can never hide a
    # real lane. This is also the exact bug that shipped first: a swallowed NameError made the live
    # set empty and the filter a silent no-op that LOOKED like it worked.
    resu = LA.build(rows_f, fs_f, None, use_jev=False, live=set())
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
        import shutil
        shutil.rmtree(_tmpd, ignore_errors=True)

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
    return mod


class TestActionVocabulary:
    @classmethod
    def setup_class(cls):
        cls.o = _objective_mod()
        cls.REQ = list(cls.o.REQUIRED)
        cls.DU = "https://github.com/o/r/actions/runs/1/job/2"

    def _cr(self, red=(), absent=(), extra_red=()):
        """A check-run list for the 7 required contexts, plus optional never-required reds."""
        out, i = [], 0
        for n in self.REQ:
            if n in absent:
                continue
            i += 1
            out.append({"id": i, "name": n, "status": "completed",
                        "conclusion": "failure" if n in red else "success",
                        "app": {"slug": "actions"}, "details_url": self.DU})
        for n in self.o.RAIL_GATES:            # the rail's own gates ride along, GREEN
            i += 1
            out.append({"id": i, "name": n, "status": "completed", "conclusion": "success",
                        "app": {"slug": "actions"}, "details_url": self.DU})
        for j, n in enumerate(extra_red):
            out.append({"id": 900 + j, "name": n, "status": "completed",
                        "conclusion": "failure", "app": {"slug": "actions"},
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

    def test_a_required_check_that_never_ran_is_work(self):
        """Absence is not green here: a required check that never ran IS the rerun-checks work."""
        assert "docs" in self.o.fix_ci_reasons(self._cr(absent=["docs"]))

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
        And a token that repeats verbatim teaches the reader to skip it."""
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
                    assert f"STUCK {beat} beats" in tok and "land or say why" in tok
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
        """The bucket is renamed in DISPLAY, not in the partition -- counts still sum."""
        assert "fix-ci" in self.o.CLASS_ORDER
        assert set(self.o.CLASS_ORDER) == {"call-rail", "blocked-by-rail", "rerun-checks",
                                           "resolve-conflict", "record-review", "fix-ci"}

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

