#!/usr/bin/env python3
"""tools/fleet/triage.test.py — hermetic suite for the lane triage router (#4046).

Zero-dep and self-runnable, shaped like its siblings (`tools/fleet/liveness.test.py`,
`tools/fleet/lane_liveness.test.py`): `python3 tools/fleet/triage.test.py` prints PASS/FAIL and
exits non-zero on any failure. No cmux, no gh, no network, no clock.

WHAT IT PINS — the five acceptance items of #4046, as assertions rather than review comments:

    PRECEDENCE      user-question > wedged > idle-continue, in BOTH directions of every pair, on the
                    SAME evidence set (each pair is presented simultaneously and the higher must win)
    NO-CONTINUE     ⛔ ZERO routes whose action is `send-continue` while the lane's last turn asks a
                    question — over a matrix of question shapes (prose, trailing phrase, permission
                    ask, question inside a code fence, quoted tool error, abstained turn boundary)
    ARMS-PROVE      every route any arm can emit names the artifact that arm must verify, and the
                    action→proof mapping is the table's, not the caller's; a mismatched pair is
                    refused before it can be executed
    WEDGED-SUBCASES every subcase in WEDGED_SUBCASES is reachable from a fixture, each has a named
                    remedy, and `send-continue` appears in NONE of them
    UNSTEERABLE     a `pi -p` lane gets `refuse`, never a `send-continue` — a nudge with no effect
                    behind it is the defect, not a lesser version of the fix
    ONE-CLASSIFIER  the router publishes no `liveness.STATES` name outside the recorded overlap, so it
                    cannot become a second liveness verdict (`docs/ops/fleet-liveness.md` §0)
    ASK-DETECTOR    the mechanical predicate's cases, including the two directions it could fail open

Every leg is paired with a RED CONTROL (`--red-control`), and the controls run by default: a suite
that cannot fail is a suite that certifies nothing.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import liveness  # noqa: E402
import triage  # noqa: E402
import triage_arms  # noqa: E402

PASS = 0
FAIL = 0


def ok(name: str, cond: bool, detail: str = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  ok   %s" % name)
    else:
        FAIL += 1
        print("  FAIL %s%s" % (name, ("  :: " + detail) if detail else ""))


def eq(name: str, got, want) -> None:
    ok(name, got == want, "got %r want %r" % (got, want))


# ── turn fixtures ───────────────────────────────────────────────────────────────────────────────
# Built with `liveness.turn_from_entry`, i.e. THE #1254 open-turn contract — never a local invention
# of what "open" means. A fixture that hand-set `Turn(stalled=True)` would pass while the real
# classifier disagreed, which is the failure this choice prevents.
TURN_ENDED = liveness.turn_from_entry(
    {"type": "message", "message": {"role": "assistant", "stopReason": "stop", "content": "done"}})
TURN_OPEN = liveness.turn_from_entry(
    {"type": "message", "message": {"role": "assistant", "stopReason": "toolUse",
                                    "content": [{"type": "toolCall", "name": "bash", "id": "c1"}]}})
TURN_ABSTAIN = liveness.turn_from_entry({"type": "compaction"})


def ev(**kw) -> triage.Evidence:
    base = dict(lane="L", turn=TURN_ENDED, last_text="Work landed; tests green.",
                lane_verdict="WIP-IDLE", steerable=True)
    base.update(kw)
    return triage.Evidence(**base)


QUESTION_TEXTS = [
    # a plain prose question
    "I finished the detection half.\n\nShould I add the router now, or wait for your answer?",
    # a permission-flavoured ask with NO question mark — the shape `tests/heartbeat-*` misses
    "The migration is written.\n\nLet me know if you want me to apply it to the staging database.",
    # "shall I" mid-sentence, ending in a statement
    "Everything is green.\n\nShall I go ahead and merge, or do you want the review first.",
    # a trivially-yes question the AGENTS.md protocol forbids
    "Research is done.\n\nReady?",
    # a question whose topic is code
    "The bug is in `parse()`.\n\nWhich option do you want: rewrite the parser, or patch the caller?",
    # ⛔ THE SHAPE THE FIRST VERSION MISSED (fresh-context review, #4046 P1): the question, then a
    # one-line declarative restatement. Reading only the FINAL paragraph read this as `not-asked` and
    # sent "continue" — the exact harmful message, through the detector's own blind spot.
    "Detection is landed and green.\n\nShould I build the router next, or wait for your ruling?\n\n"
    "Blocked on your decision.",
    # same, with a status the phrase list learned from the same finding
    "The options are written up.\n\nWaiting on you.",
    # ⛔ THE ADDRESSED APPROVAL ASK, WRITTEN WITHOUT A QUESTION MARK (round 3, #4046 P1). All five
    # escaped `_HANDOFF` and routed a lane awaiting the owner to `idle-continue`/`send-continue` — the
    # headline harm, through the class that exists to catch exactly this shape.
    "The PR is green.\n\nWaiting for your approval to merge.",
    "The PR is green and I'll merge on your approval.",
    "Please approve the merge so I can land it.",
    "I need approval before merging.",
    "Everything is green. I'll land it once you approve.",
    "Done. Tell me if the merge should wait.",
    # ⛔ THE GO-AHEAD FAMILY (round 4, #4046 P0). Measured through `route_gate` before the fix, 10 of
    # 10 realistic approval asks returned `may_nudge=True` and `turn-end.py` typed "continue" into a
    # lane waiting on the owner. These four are the ones that were still open after round 3.
    "Migration written and tested. I'll wait for your go-ahead before applying it to prod.",
    "Blocked on your decision.\n\nEverything else is green.",
    "Let me know if you want the migration run.\n\nSuite is green.",
    "The rollout is staged.\n\nWaiting to hear whether to proceed.",
    # ⛔ THE ROUND-5 HAND-OFF CORPUS (P1). At 502fa170a, 21 of 25 of a hand-written hand-off corpus
    # read `not-asked`; these are the ten UNAMBIGUOUS ones, and every one routed `send-continue`.
    "I'm holding the deploy until you say otherwise.",
    "Ping me when you've picked one.",
    "I'll pause here for your input.",
    "Awaiting instruction.",
    "Your move.",
    "Reply and I'll continue.",
    "Tell me to proceed and I will.",
    "Awaiting a steer on the API shape.",
    "This needs your input before I go further.",
    # the fleet's lanes write in Spanish when the owner does; an English-only detector answers
    # `not-asked` to an obvious hand-off.
    "Quedo a la espera de tu aprobación para aplicar.",
    # ⛔ AND A QUESTION THE PHRASE LIST DOES NOT NAME (round 5, #4046 P2). Mutation-measured after the
    # round-5 fixes: disabling the `?` rule entirely left the suite GREEN, because every fixture also
    # matched a listed phrase — so the rule that carries questions like these had no discriminating
    # leg at all. These four are pure `?` asks: no interrogative frame, no hand-off vocabulary.
    "Did the patch land cleanly?",
    "Is the cache warm enough for the load test?",
    "Any reason the rail would refuse this one?",
    "Can the migration be re-applied without dropping the index?",
    # ⛔ THE CLAUSE-SCOPED DISARM (round 6, #4046 P0). Whole-sentence disarming let a temporal anchor
    # or a denial in a NEIGHBOURING clause silence a live ask in the same sentence: measured, these
    # four read `not-asked` and routed `send-continue` on a settled turn and `rerun` on an open one.
    "I'm blocked on your approval, unlike yesterday.",
    "Nothing needs your input on the schema, but I do need your approval on the deploy.",
    "Awaiting your decision — I'll be at 14:02 standup and then free.",
    "The migration is written. I'll hold the deploy until you confirm; I'm back at 14:02.",
]


# ── leg 1: precedence ───────────────────────────────────────────────────────────────────────────
def leg_precedence() -> None:
    print("\n── PRECEDENCE — user-question > wedged > idle-continue ──")

    # all three situations present at once: a question on a resting turn, a lane that ALSO carries a
    # WEDGED verdict, and everything that would otherwise make it idle.
    both = ev(turn=TURN_ENDED, last_text="Done.\n\nShould I apply the migration?",
              lane_verdict="WEDGED")
    eq("question beats wedged", triage.route(both).route, "user-question")

    both2 = ev(turn=TURN_ABSTAIN, last_text="Done.\n\nShould I apply the migration?",
               lane_verdict="WEDGED", boot_prompt=True)
    eq("question beats wedged even on an ABSTAINED boundary", triage.route(both2).route,
       "user-question")

    wedged_and_idle = ev(lane_verdict="CHILD-STUCK", steerable=True)
    eq("wedged beats idle", triage.route(wedged_and_idle).route, "wedged")

    # ⛔ AN IDLE VERDICT WE COULD NOT READ IS A REFUSAL, NOT "NOTHING TO DO" (round 5, #4046 P1).
    # `none`/`none` here meant an unreadable lane vanished from `lane-route.py`'s `router=refuse:N`
    # count AND had its nudge suppressed on every tick — a fleet-wide unreadable population read as a
    # quiet fleet.
    for verdict in ("WIP-IDLE", "DONE-IDLE", "EMPTY", "UNBOUND"):
        ru = triage.route(ev(lane_verdict=verdict, turn=None, last_text=""))
        eq("an idle verdict on an UNREAD turn refuses (%s)" % verdict, ru.action, "refuse")
    eq("…while a genuinely working lane still routes nowhere",
       triage.route(ev(lane_verdict="WORKING", turn=None, last_text="")).action, "none")

    # ⛔ A QUESTION ON AN OPEN TURN MUST NOT BE RELAUNCHED (round 4, #4046 P1). `liveness.Turn(True,
    # "turn-open:no-terminal-stop")` — a turn that carries text but no terminal stop, the
    # crash/hang-mid-write shape — falls through the question arm (which requires a RESTING boundary)
    # into the wedge ladder, and `open-turn-never-closes`'s remedy is `rerun`. Measured before the
    # veto: 27 of 468 enumerated combinations reached a lane-destroying action from a lane that had
    # asked. A relaunch destroys the question exactly as a "continue" answers it wrongly.
    for verdict in ("WEDGED", "DONE-IDLE", "", "UNKNOWN"):
        q_open = ev(turn=TURN_OPEN, last_text="Should I merge, or wait?", lane_verdict=verdict,
                    steerable=True)
        rq = triage.route(q_open)
        ok("an open turn that ASKS is never rerun (verdict=%r)" % (verdict,),
           rq.action != "rerun", "%s/%s" % (rq.route, rq.action))
    # and the positive control: no question, same evidence, the wedge remedy is still reachable
    nq_open = ev(turn=TURN_OPEN, last_text="Working through the ladder.", lane_verdict="WEDGED",
                 steerable=True)
    eq("…while a non-questioning open wedge still routes to its own remedy",
       triage.route(nq_open).action, "rerun")

    # and the ordering's own edge: an OPEN turn is not a resting question, so a mid-flight question
    # mark must NOT be promoted over the wedge evidence.
    open_midflight = ev(turn=TURN_OPEN, last_text="Checking whether `/tmp` is writable?",
                        lane_verdict="CHILD-STUCK")
    eq("an OPEN turn's question mark is not the lane asking", triage.route(open_midflight).route,
       "wedged")

    # a clean idle lane is still idle: the precedence must not swallow the third arm.
    eq("a clean resting lane routes idle-continue", triage.route(ev()).route, "idle-continue")

    # the route set is published in precedence order, and `route()` can only return a member
    eq("ROUTES is in precedence order", triage.ROUTES,
       ("user-question", "wedged", "idle-continue", "none"))
    for e in (both, both2, wedged_and_idle, ev(), ev(lane_verdict="WORKING")):
        ok("route() returns a published route for %r" % (e.lane_verdict,),
           triage.route(e).route in triage.ROUTES)


# ── leg 2: ⛔ zero "continue" in reply to a question ────────────────────────────────────────────
def leg_no_continue_to_question() -> None:
    print("\n── NO-CONTINUE — zero 'continue' sent in reply to a question ──")
    # The matrix varies EVERY dimension a caller could use to argue the lane looks idle: each verdict
    # that can reach the idle arm, steerability, child state, boot prompt — with a question on the
    # turn's tail in each case. The assertion is not "the first arm won", it is the property itself.
    verdicts = ("WIP-IDLE", "DONE-IDLE", "EMPTY", "UNBOUND", "WEDGED", "CHILD-STUCK", "")
    fired = []
    for text in QUESTION_TEXTS:
        for verdict in verdicts:
            for steer in (True, False, None):
                for turn in (TURN_ENDED, TURN_ABSTAIN, TURN_OPEN):
                    r = triage.route(ev(turn=turn, last_text=text, lane_verdict=verdict,
                                        steerable=steer))
                    if r.action == "send-continue":
                        fired.append((text[:40], verdict, steer, getattr(turn, "reason", "?")))
    ok("no send-continue for ANY question shape x verdict x steerability x turn boundary",
       not fired, "fired on: %r" % (fired[:3],))

    # the honest other half: the SAME matrix with a non-question must still be able to reach the arm,
    # or the assertion above is satisfied by an arm that never fires at all.
    reached = any(triage.route(ev(last_text="Work landed; tests green.", lane_verdict=v,
                                  steerable=True)).action == "send-continue"
                  for v in ("WIP-IDLE", "DONE-IDLE"))
    ok("…and the idle arm still FIRES for a genuinely non-question resting lane", reached)

    # an unread tail is not a proven-clean tail: it must not reach the send either
    eq("an unread tail routes refuse, never send-continue",
       triage.route(ev(last_text="", lane_verdict="DONE-IDLE")).action, "refuse")


# ── leg 3: every arm proves its effect at the artifact ──────────────────────────────────────────
def leg_arms_prove() -> None:
    print("\n── ARMS-PROVE — every arm names the artifact it must verify ──")
    fixtures = {
        "question": ev(last_text="Should I merge?", lane_verdict="WIP-IDLE"),
        "idle": ev(lane_verdict="WIP-IDLE"),
        "child-stuck": ev(lane_verdict="CHILD-STUCK"),
        "child-overdue": ev(lane_verdict="CHILD-OVERDUE"),
        "boot-prompt": ev(lane_verdict="DONE-IDLE", boot_prompt=True),
        "model-retry": ev(lane_verdict="WEDGED", model_retry=True, turn=TURN_OPEN),
        "tool-in-flight": ev(lane_verdict="LONG-TOOL", tool_in_flight=True, tool_budget_open=True,
                             turn=TURN_OPEN),
        "open-turn": ev(lane_verdict="WEDGED", turn=TURN_OPEN),
        "wedged-unverified": ev(lane_verdict="WEDGED", turn=TURN_ENDED),
        "unsteerable": ev(lane_verdict="DONE-IDLE", steerable=False),
        "working": ev(lane_verdict="WORKING", turn=TURN_OPEN),
    }
    for name, e in fixtures.items():
        r = triage.route(e)
        ok("%s: route names a proof" % name, bool(r.proof) and r.proof == triage.PROOFS.get(r.action),
           "%r -> action=%r proof=%r" % (r.route, r.action, r.proof))
        ok("%s: route is executable (complete)" % name, r.complete,
           "route=%r action=%r proof=%r" % (r.route, r.action, r.proof))
        ok("%s: names the artifact it verified" % name, bool(r.evidence),
           "evidence=%r" % (r.evidence,))

    # `SENT` is not an effect: the proof for the continue arm is transcript growth BY NAME.
    eq("the continue arm's proof is transcript growth",
       triage.PROOFS["send-continue"], "transcript-growth")
    ok("a 'SENT' marker is not offered as a proof anywhere",
       not any("sent" in p for p in triage.PROOFS.values()),
       repr(sorted(set(triage.PROOFS.values()))))


# ── leg 4: wedged subcases ──────────────────────────────────────────────────────────────────────
def leg_wedged_subcases() -> None:
    print("\n── WEDGED-SUBCASES — each has a fixture, a named remedy, and no 'continue' ──")
    fixtures = {
        "child-stuck": ev(lane_verdict="CHILD-STUCK"),
        "child-overdue": ev(lane_verdict="CHILD-OVERDUE"),
        "boot-prompt": ev(lane_verdict="DONE-IDLE", boot_prompt=True),
        "model-retry": ev(lane_verdict="WEDGED", model_retry=True, turn=TURN_OPEN),
        "tool-in-flight": ev(lane_verdict="LONG-TOOL", tool_in_flight=True, tool_budget_open=True,
                             turn=TURN_OPEN),
        "open-turn-never-closes": ev(lane_verdict="WEDGED", turn=TURN_OPEN),
        "wedged-unverified": ev(lane_verdict="WEDGED", turn=TURN_ENDED),
    }
    eq("every declared subcase has a fixture", set(fixtures), set(triage.WEDGED_SUBCASES))
    for name, e in fixtures.items():
        r = triage.route(e)
        eq("%s: routed to its own subcase" % name, r.subcase, name)
        eq("%s: remedy is the SUB's, not a generic one" % name, r.action, triage.REMEDIES[name])
        ok("%s: remedy is not send-continue" % name, r.action != "send-continue", r.action)
        ok("%s: remedy is named" % name, bool(r.action))

    ok("no wedged remedy is 'send-continue'",
       "send-continue" not in set(triage.REMEDIES.values()),
       repr(sorted(set(triage.REMEDIES.values()))))
    ok("every subcase has a remedy", set(triage.REMEDIES) == set(triage.WEDGED_SUBCASES))

    # the two subcases where the correct answer is DELIBERATELY not to act — pinned so a later
    # "improvement" cannot quietly turn them into a kill or a nudge.
    eq("a declared tool budget is waited out, never killed",
       triage.route(fixtures["tool-in-flight"]).action, "wait")
    eq("a WEDGED verdict the turn does not support is INSPECTED, never acted on",
       triage.route(fixtures["wedged-unverified"]).action, "inspect")


# ── leg 5: the unsteerable lane ────────────────────────────────────────────────────────────────
def leg_unsteerable() -> None:
    print("\n── UNSTEERABLE — a `pi -p` lane is refused, never nudged into the void ──")
    for steer, why in ((False, "pi -p"), (None, "unread")):
        r = triage.route(ev(lane_verdict="WIP-IDLE", steerable=steer))
        eq("steerable=%r routes none" % (steer,), r.route, "none")
        eq("steerable=%r action is refuse" % (steer,), r.action, "refuse")
        ok("steerable=%r never sends continue" % (steer,), r.action != "send-continue")
        ok("steerable=%r says why" % (steer,), why in r.reason or "steerable" in r.reason, r.reason)
    # and the positive control: the same lane, steerable, DOES take the arm.
    eq("steerable=True takes the idle-continue arm",
       triage.route(ev(lane_verdict="WIP-IDLE", steerable=True)).route, "idle-continue")


# ── leg 6: one classifier, not two ─────────────────────────────────────────────────────────────
def leg_one_classifier() -> None:
    print("\n── ONE-CLASSIFIER — the router publishes no liveness state ──")
    eq("the only state/route name shared with liveness is the recorded one",
       triage.STATES_DISJOINT, triage.ALLOWED_STATE_OVERLAP)
    ok("`wedged` is the ONLY overlap, and it is disclosed",
       triage.STATES_DISJOINT == frozenset({"wedged"}))
    # the router CONSUMES liveness.Turn — pin the three fields it reads, so a change to the verdict
    # function's contract fails here rather than silently misrouting every lane.
    for attr in ("stalled", "reason", "abstain"):
        ok("liveness.Turn still carries .%s" % attr, hasattr(TURN_ENDED, attr))


# ── leg 7: the mechanical question detector ────────────────────────────────────────────────────
def leg_ask_detector() -> None:
    print("\n── ASK-DETECTOR — mechanical, and conservative in the harmful direction ──")
    for text in QUESTION_TEXTS:
        eq("asks_owner(asked): %r" % text[-32:], triage.asks_owner(text), "asked")

    NOT_Q = [
        "Work landed. Tests green, PR #1 opened and merged.",
        "I asked whether the option was viable, and the answer was no.",
        "Fixed the parser (`parse()` now returns a list).",
        # a question mark inside a fenced block is not the lane asking anything
        "Patched the template.\n\n```\n# is this file writable?\nsed -n 1p f\n```\n\nWrote it and verified.",
        # a quoted tool error ending in a question mark
        "The child tool returned:\n\n> Invalid config: which option did you mean?\n\nRetried with the explicit path.",
        # ⛔ THE FALSE POSITIVES ROUND 2 FOUND (P1): `confirm`/`approve` matched as BARE SUBSTRINGS, so
        # five of six realistic completion endings read as the lane asking the owner. Each one would
        # have routed a finished lane to the question lane and SUPPRESSED its nudge — a detector that
        # fires on "Confirmed" is worse than none.
        "Landed the change.\n\nConfirmed the parser returns a list.",
        "Merge is done.\n\nApproved by the rail and green.",
        "Rebuilt and re-ran.\n\nConfirmed: 210 pass, 0 fail.",
        "The rail approved the merge.\n\nConfirmed on main at 2286999.",
        "Everything landed.\n\nApproved and confirmed by the merge rail.",
        # ⛔ A `?` INSIDE A TOKEN IS NOT AN ASK (round 4, #4046 P2). Both of these routed a FINISHED
        # lane to the owner's question lane and suppressed its nudge before the token rule.
        "Deployed to https://ops.example.com/health?full=1 and it returned 200.\n\nAll green.",
        "Wrote the rule to docs/faq?/README.md and confirmed it lands.",
        # ⛔ PAST-TENSE COMPLETION PROSE (round 5, #4046 P1). Widening the phrase classes to the whole
        # tail made 7 of these 8 read `asked`, routing a FINISHED lane to the owner's question lane and
        # suppressing its nudge — a regression of the fix round 2 made. The disarm is per SENTENCE and
        # tense-aware: "I'll merge on your approval" stays an ask, "Merged it on your approval at
        # 14:02" does not.
        "Merged the PR on your approval at 14:02, checks green.",
        "Everything went through after your approval yesterday.",
        "That join was your call and it held up.",
        "Recorded your decision in the doc; shipped it.",
        "The plan matched your approval exactly.",
        "Landed it pending your approval from Monday.",
        "Rebased onto main and merged. Nothing needs your input now.",
        # the same rule's other side: a cue in the SAME clause still disarms, and a quoted command is
        # reported material (round 6, #4046 P2 — inline code was read as prose)
        "Thanks for your approval.",
        "Holding the deploy was the right call.",
        "Ran `grep -c '?' file` and got 0.",
    ]
    for text in NOT_Q:
        eq("asks_owner(not-asked): %r" % text[:38], triage.asks_owner(text), "not-asked")

    eq("an empty read is `unread`, never `not-asked`", triage.asks_owner(""), "unread")
    eq("a fence-only read is `unread`", triage.asks_owner("```\ncode\n```"), "unread")

    # a supplied Jev verdict may PROMOTE but never DEMOTE — the harm is one-directional
    eq("a supplied `asked` wins over a mechanical not-asked",
       triage.route(ev(last_text="All done.", ask_signal="asked")).route, "user-question")
    eq("a supplied `not-asked` cannot talk down a mechanical asked",
       triage.route(ev(last_text="All done.\n\nReady?", ask_signal="not-asked")).route,
       "user-question")
    # ⛔ AND AN UNREAD TAIL BEATS A SUPPLIED `not-asked` (fresh-context review, #4046 P2).
    eq("an unread tail is UNREAD even when a caller asserts `not-asked`",
       triage.route(ev(last_text="", ask_signal="not-asked", lane_verdict="WIP-IDLE")).action,
       "refuse")

    # the P1 shape as its own named assertion, so a later narrowing of the window is red here
    eq("a question followed by a declarative status is still a question",
       triage.asks_owner("Landed.\n\nShould I merge, or wait?\n\nBlocked on your decision."), "asked")
    # ⛔ AND A QUESTION FOLLOWED BY **TWO** STATUS PARAGRAPHS (round 2, #4046 P1). Widening a paragraph
    # window only moves the boundary — this shape falsified the 2-paragraph version exactly as the
    # 1-paragraph version was falsified before it. So the window is gone.
    eq("a question followed by TWO status paragraphs is still a question",
       triage.asks_owner("Should I merge the PR now?\n\nI checked the diff twice.\n\nNothing else in "
                         "the tree moved."), "asked")
    eq("a completion report is not a question",
       triage.asks_owner("Rebuilt and re-ran.\n\nConfirmed: 210 pass, 0 fail."), "not-asked")
    eq("a hand-off with no question mark IS a question",
       triage.asks_owner("The parser is patched.\n\nBlocked on your decision about RLS."), "asked")


# ── leg 8: route_rows carries the population through ──────────────────────────────────────────
def leg_rows() -> None:
    print("\n── ROWS — the real population shape reaches the same decisions ──")
    rows = [
        {"lane": "A", "verdict": "WIP-IDLE", "steerable": True, "turn": TURN_ENDED,
         "last_text": "Should I merge it?"},
        {"lane": "B", "verdict": "WIP-IDLE", "steerable": True, "turn": TURN_ENDED,
         "last_text": "Landing the router now."},
        {"lane": "C", "verdict": "CHILD-STUCK", "steerable": True, "turn": TURN_OPEN},
        {"lane": "D", "verdict": "WORKING", "steerable": True, "turn": TURN_OPEN},
    ]
    out = triage.route_rows(rows)
    eq("one route per row", len(out), 4)
    eq("the question row routes to the question lane", out[0]["route"], "user-question")
    eq("the idle row routes to continue", out[1]["action"], "send-continue")
    eq("the child row routes to its subcase", out[2]["subcase"], "child-stuck")
    eq("the working row routes nowhere", out[3]["action"], "none")
    ok("rows are self-describing (lane preserved)", [r["lane"] for r in out] == ["A", "B", "C", "D"],
       repr([r["lane"] for r in out]))
    line = triage.summary(out)
    ok("the summary names the question lane", "A" in line, line)
    ok("the summary is one line", "\n" not in line, line)

    # ⛔ THE PRODUCER'S OWN TOOL KEY (round 4, #4046 P2). `lane-status.py` emits the in-flight call as
    # a DICT under `tool`; it never emits `tool_in_flight`. Reading only the invented key left the
    # expired-budget branch UNREACHABLE through `route_rows` — the same producer-key-set defect fixed
    # in `lane-route.evidence_for` in round 3, standing in the sibling function because nothing in
    # production called it. Both sides of the budget are now driven through the real row shape.
    tool_rows = [
        {"lane": "T1", "verdict": "WEDGED", "tool": {"name": "bash", "timeout": 3000, "age": 60}},
        {"lane": "T2", "verdict": "WEDGED", "tool": {"name": "bash", "timeout": 3000, "age": 9000}},
    ]
    tout = triage.route_rows(tool_rows)
    eq("a tool INSIDE its declared budget is not a wedge", tout[0]["action"], "wait")
    eq("a tool that OVERRAN its own budget is inspected", tout[1]["action"], "inspect")
    ok("…and both are reached through the producer's `tool` dict, not an invented key",
       tout[0]["subcase"] == "tool-in-flight" and tout[1]["subcase"] == "tool-in-flight",
       repr([t["subcase"] for t in tout]))

    # ⛔ AND A READING ARM SAYS SO (round 4, #4046 P2): `verified` on `wait`/`inspect`/`refuse`/`none`
    # means only that the reading was produced, which is true of a lane nothing was done to. The
    # record carries the distinction so a reader cannot grep `verified: true` and conclude an effect.
    for action in ("wait", "inspect", "refuse", "none"):
        pr = triage_arms.arm_reading(action, "a reason")
        ok("a reading arm is NOT an assertion about the lane: %s" % action,
           pr.verified and pr.asserts_lane is False, pr.as_dict())
    pe = triage_arms.arm_rerun("L", "ws", lambda ws: 0)
    ok("…while an effect arm DOES assert the lane", pe.asserts_lane is True, pe.as_dict())


# ── RED CONTROLS ───────────────────────────────────────────────────────────────────────────────
def run_red_control() -> bool:
    """Mutate the router and prove each mutation the arms exist to prevent turns a leg RED.

    A control that cannot fail certifies nothing, so each one is a NEGATIVE assertion: the mutated
    decision must NOT satisfy the property the shipped one satisfies.
    """
    print("\n── RED CONTROLS — the suite must fail when a property is removed ──")
    good = True

    # (R1) PRECEDENCE — mutate the SHIPPED router's decision order and prove the shipped one differs.
    # ⛔ THE FIRST VERSION OF THIS CONTROL WAS A TAUTOLOGY (round 2, #4046 P2): it asserted on a mutant
    # `Route` the test had just constructed, so deleting `route()`'s question arm left it green. The
    # control now runs the SAME evidence through both and requires them to DISAGREE.
    e_q = ev(last_text="Should I merge?", lane_verdict="WEDGED")
    shipped = triage.route(e_q).route
    good &= _red("R1 precedence: a wedged-first order WOULD misroute this question", shipped == "user-question")
    good &= _red("R1b …and the shipped router's answer differs from the wedged-first answer",
                 shipped != "wedged")

    # (R2) THE QUESTION GUARD — mutate the shipped DETECTOR (the guard's own input) and prove the
    # shipped router's answer changes. This is a real mutation of shipped code: if the router stopped
    # consulting the detector, `route()` would return send-continue in BOTH arms and this control goes
    # red, while a tautology asserting a locally built Route would stay green (round 2, #4046 P2).
    shipped_action = triage.route(e_q).action
    _real_asks = triage.asks_owner
    try:
        triage.asks_owner = lambda text: triage.NOT_ASKED      # the "guard removed" mutation
        mutated_action = triage.route(ev(last_text="Should I merge?")).action
    finally:
        triage.asks_owner = _real_asks
    good &= _red("R2 the shipped router does not send continue to a question",
                 shipped_action != "send-continue")
    good &= _red("R2b …and with the detector muted the SAME call DOES send continue "
                 "(so the guard is what stops it, not an arm that never fires)",
                 mutated_action == "send-continue")

    # (R3) the steerability guard: the REAL router must be what refuses, not a route the test built.
    # (First version asserted a locally-constructed Route and stayed green with the guard deleted.)
    good &= _red("R3 the router refuses a `pi -p` lane (guard deleted would send)",
                 triage.route(ev(lane_verdict="WIP-IDLE", steerable=False)).action != "send-continue")

    # (R4) an arm with no proof must be REFUSED as unexecutable.
    bad = triage.Route(route="idle-continue", action="send-continue", proof="", reason="mutant")
    good &= _red("R4 an arm naming no artifact is not executable", not bad.complete)

    # (R5) a mismatched action/proof pair is refused — the table is the authority, not the caller.
    bad = triage.Route(route="user-question", action="route-to-question-lane",
                       proof=triage.PROOFS["send-continue"], reason="mutant")
    good &= _red("R5 an action carrying someone else's proof is not executable", not bad.complete)

    # (R6) the detector must fail CLOSED on a question mark in a fence — a detector that read it as
    # the lane asking would route every code-reading lane to the owner. ⛔ A MUTATION, NOT A FIXED
    # STRING (round 3, #4046 P2): asserting one input's answer observes nothing about the stripper,
    # so the control now disables the stripper and requires the SAME input's answer to CHANGE.
    _fence = triage._FENCE_RE
    fenced = "Landed it.\n\n```\nshall i merge?\n```"
    clean_answer = triage.asks_owner(fenced)
    triage._FENCE_RE = re.compile(r"(?!x)x")          # fence-blind mutant
    try:
        blind_answer = triage.asks_owner(fenced)
    finally:
        triage._FENCE_RE = _fence
    good &= _red("R6 a fence-blind detector WOULD call a fenced question an ask",
                 clean_answer == "not-asked" and blind_answer == "asked")

    # (R7) the router must not become a second verdict function.
    good &= _red("R7 a router that republished 'dead' would be a second liveness verdict",
                 "dead" not in triage.ROUTES)

    # (R8) a question brief that DROPPED the mandate must not be routed — a question forwarded raw
    # has been relayed, not answered.
    relayed = "Lane X asks: should we merge?"
    good &= _red("R8 a mandate-free brief is refused before it is sent",
                 bool(triage_arms.mandate_missing(relayed)))

    # (R9) the CONTINUE arm's own predicate: a lane that did not grow must not verify. The first
    # version asserted a locally-built Proof and proved nothing about the arm.
    class _Frozen(FakeSurface):
        def __init__(self):
            super().__init__(sizes={"ws_z": 5})

        def send(self, ws, text):
            self.sent.setdefault(ws, []).append(text)
            return True                      # sent, but the transcript NEVER moves

    p = triage_arms.execute(triage.route(ev(lane_verdict="WIP-IDLE")), ev(lane_verdict="WIP-IDLE"),
                            _Frozen(), ws="ws_z")
    good &= _red("R9 a send whose transcript did not move is NOT verified",
                 (p.sent is True) and (p.verified is False))

    # (R10) a question routed through the OWNING lane would be the exact harm.
    class _OwnerOnly(FakeSurface):
        def __init__(self):
            super().__init__(spaces=[{"id": "ws_owner", "name": "lane-7", "index": 0}])

    s = _OwnerOnly()
    triage_arms.execute(triage.route(ev(last_text="Should I merge?")),
                        ev(lane="lane-7", last_text="Should I merge?"), s, ws="ws_owner")
    good &= _red("R10 the question arm must never type into the owning lane",
                 "ws_owner" not in s.sent)

    # (R11) ⛔ THE COMPLETION GATE ON A TEMPORAL ANCHOR IS LOAD-BEARING (round 7, #4046 P0). Without
    # it any clause carrying a date disarms, and an ask whose OBJECT merely dates — "Please approve
    # yesterday's expense report." — reads as a report. A MUTATION: restore the unconditional anchor
    # and require the SAME input's answer to change.
    # ⛔ THE FIXTURE MUST CARRY NO `_FUTURE_CUE` (round 8, #4046 P2). The first version used
    # "Please approve yesterday's expense report." — whose `Please` is itself a future cue — so a
    # MUCH WEAKER rule ("an anchor disarms unless a future cue is present", with no completion gate)
    # also passed it, and no longer silenced it. That is how a completion gate that did not gate
    # survived a round: the control could not tell the fix from a weaker rule that also failed.
    dated = "Your confirmation on the plan we decided yesterday."
    shipped_ask = triage.asks_owner(dated)
    _real_disarmed = triage._disarmed
    triage._disarmed = (lambda low, *a, **kw: bool(triage._PAST_HARD_ANCHOR.search(low))
                        or _real_disarmed(low, *a, **kw))
    try:
        anchored_ask = triage.asks_owner(dated)
    finally:
        triage._disarmed = _real_disarmed
    good &= _red("R11 an unconditional date anchor WOULD silence a dated ask",
                 shipped_ask == "asked" and anchored_ask == "not-asked")

    # (R13) ⛔ THE CUE'S POSITION IS WHAT DOES THE WORK (round 8, #4046 P0). The round-7 gate asked
    # only whether a completion verb was present in the clause, and the ASK's own object supplies one
    # ("the invoice I sent last week", "the plan we decided yesterday"). Mutant: drop the addressed
    # cue, so the completion can no longer be attributed to the object.
    _real_addressed = triage._ADDRESSED
    # The fixture carries an addressed cue that is NOT a `_FUTURE_CUE` ("your confirmation") and a
    # completion inside the ask's object ("we decided"), so the position rule is the only thing
    # standing between it and the disarm — which is what makes the mutant discriminating. The mutant
    # is the round-8 `_disarmed` body verbatim (position rule absent): R13 has to mutate the RULE,
    # because no second cue list is consulted any more (that is R15's mutation).
    obj_ask = "Your confirmation on the plan we decided yesterday."

    def _round8_disarmed(low, cue_at=None):            # the previous body, position rule removed
        if _real_disarmed.__globals__["_PAST_HARD_DENIAL"].search(low) or \
                triage._PAST_HARD_FRAME.search(low):
            return True
        if triage._PAST_HARD_ANCHOR.search(low):
            return bool(triage._COMPLETION.search(low)) and not triage._FUTURE_CUE.search(low)
        return bool(triage._PAST_SOFT.search(low)) and not triage._FUTURE_CUE.search(low)

    triage._disarmed = _round8_disarmed
    try:
        blind_ask = triage.asks_owner(obj_ask)
    finally:
        triage._disarmed = _real_disarmed
    good &= _red("R13 without the position rule a completion IN THE OBJECT silences the ask",
                 blind_ask == "not-asked" and triage.asks_owner(obj_ask) == "asked")

    # (R14) ⛔ THE COMPLETION LIST IS LOAD-BEARING ON THE REPORT SIDE (round 8, #4046 P1). A closed
    # list of completions let a finished lane's ending read `asked`, suppressing its nudge. Mutant:
    # restore the round-7 list (no `passed`) and require the answer to change.
    _real_completion = triage._COMPLETION
    report = "All 1436 tests passed at 14:02 after your approval."
    good &= _red("R14 the shipped completion list reads a finished lane as finished",
                 triage.asks_owner(report) == "not-asked")
    triage._COMPLETION = re.compile(
        r"\b(?:merged|shipped|approved|decided|landed|closed|pushed|deployed|committed|completed|"
        r"finished|done|went through|ran|wrote|sent|opened|removed|added|fixed|recorded|signed)\b")
    try:
        narrow_report = triage.asks_owner(report)
    finally:
        triage._COMPLETION = _real_completion
    good &= _red("R14b …and the round-7 list WOULD have read that same ending as a question",
                 narrow_report == "asked")

    # (R15) ⛔ THE CUE OFFSET MUST COME FROM THE PHRASE THAT ADMITTED THE CLAUSE, NOT A SECOND LIST
    # (round 9, #4046 P0). The round-8 position rule used a private `_ADDRESSED` regex covering 25 of
    # the module's 59 hand-off phrases, so an ask phrased with any of the other 34 ("awaiting
    # approval", "over to you", "ping me", "your read on", …) had no offset and the completion gate
    # silently did not apply: measured 14 of 14 read `not-asked`. Mutant: stop passing the offset, so
    # the narrow fallback list is all there is.
    uncovered = "Awaiting approval on the hotfix we released yesterday."
    _real_disarmed2 = triage._disarmed
    triage._disarmed = lambda low, cue_at=None: _real_disarmed2(low, None)
    try:
        fallback_ask = triage.asks_owner(uncovered)
    finally:
        triage._disarmed = _real_disarmed2
    good &= _red("R15 an ask whose hand-off phrase is outside the fallback list would be silenced",
                 triage.asks_owner(uncovered) == "asked" and fallback_ask == "not-asked")

    # (R16) ⛔ THE CLOSING SENTINEL IS WHAT PROVES THE QUESTION ARRIVED (round 9, #4046 P0). The six
    # mandate tokens all precede the question body, so a paint cut after them certified a brief whose
    # question never landed (the smallest such prefix was 1061 of 1409 chars). Mutant: drop the end
    # marker from the brief, and require the same truncated paint to verify.
    q_full = triage_arms.question_brief("lane-7", "Shall I merge the new thing?")
    q_id = triage_arms.question_qid("lane-7", "Shall I merge the new thing?")
    cut_after_mandate = q_full[:1067]                 # past `recommendation`, before the question
    good &= _red("R16 a paint truncated after the mandate does not verify",
                 bool(triage_arms.mandate_missing(cut_after_mandate, q_id))
                 and triage_arms.mandate_missing(q_full, q_id) == [])
    # The mutant is the round-8 `mandate_missing` body verbatim: qid high-water mark + mandate, no
    # closing sentinel. It must call the truncated paint a PASS, or the sentinel is decoration.
    def _pre_delta_mandate(brief, qid=""):
        low = " ".join((brief or "").lower().split())
        if qid:
            ms = list(re.finditer(r"\s*".join(re.escape(c) for c in qid.lower()), low))
            if not ms:
                return [qid]
            low = low[ms[-1].end():]
        return [tok for tok in triage_arms.QUESTION_MANDATE if tok.lower() not in low]

    cut_1200 = q_full[:1200]                          # header + mandate present, the QUESTION gone
    good &= _red("R16b …and the pre-sentinel predicate WOULD have verified that paint",
                 _pre_delta_mandate(cut_1200, q_id) == []
                 and bool(triage_arms.mandate_missing(cut_1200, q_id)))

    # (R12) ⛔ THE PER-QUESTION ID IS WHAT DEFEATS A STALE PANE (round 7, #4046 P0). The question
    # lane is persistent, so its tail still shows the PREVIOUS brief, and both briefs carry the same
    # mandate tokens. Mutant: drop the id and the stale pane certifies the new question.
    prior7 = triage_arms.question_brief("lane-7", "Shall I merge the old thing?")

    class _NeverPaints(FakeSurface):
        def send(self, ws, text):
            self.last_sent[ws] = text
            return True

    def _stale_surface():
        return _NeverPaints(spaces=[{"id": "own", "name": "lane-7", "index": 1},
                                    {"id": "ws_q", "name": triage_arms.QUESTION_LANE,
                                     "index": 3}],
                            screens={"ws_q": prior7})

    _real_qid = triage_arms.question_qid
    triage_arms.question_qid = lambda lane, q: ""        # the "no nonce" mutation
    try:
        blind = triage_arms.arm_user_question("own", "lane-7", "Shall I merge the new thing?",
                                                _stale_surface(), nap=lambda _s: None)
    finally:
        triage_arms.question_qid = _real_qid
    honest = triage_arms.arm_user_question("own", "lane-7", "Shall I merge the new thing?",
                                           _stale_surface(), nap=lambda _s: None)
    good &= _red("R12 without the per-question id a STALE pane certifies the new question",
                 blind.verified is True and honest.verified is False)

    print("\n  RED controls: %s" % ("all fired" if good else "SOME DID NOT FIRE"))
    return good


def _red(name: str, cond: bool) -> bool:
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  ok   %s" % name)
        return True
    FAIL += 1
    print("  FAIL %s (the control did not fire — the property is not actually pinned)" % name)
    return False


# ── leg 9: the arms, against a fake surface ─────────────────────────────────────────────────────
class FakeSurface(triage_arms.Surface):
    """A surface that records every typed payload per workspace, so a leg can assert on the ARTIFACT.

    `sizes` is the transcript-size reading per workspace, mutated by `grow()` — that is what lets a
    leg distinguish "we sent" from "the lane advanced", which is the whole point of the arms.
    """

    def __init__(self, spaces=None, sizes=None, screens=None, fail_send=False,
                 move_ignored=False, screen_unreadable=False):
        self.spaces = list(spaces or [])          # [{id, name, index}]
        self.sizes = dict(sizes or {})
        self.screens = dict(screens or {})
        self.sent = {}                             # ws -> [texts]
        self.moves = []
        self.last_sent = {}
        self.fail_send = fail_send
        self.move_ignored = move_ignored
        self.screen_unreadable = screen_unreadable

    def list_workspaces(self):
        return list(self.spaces)

    def new_workspace(self, name):
        ws = "ws_new_%d" % (len(self.spaces) + 1)
        self.spaces.append({"id": ws, "name": name, "index": len(self.spaces)})
        return ws

    def move_workspace(self, ws, index):
        self.moves.append((ws, index))
        if self.move_ignored:          # rc 0, listing unchanged — the pair the proof must separate
            return True
        for sp in self.spaces:
            if sp["id"] == ws:
                sp["index"] = index
        return True

    def send(self, ws, text):
        if self.fail_send:
            return False
        self.sent.setdefault(ws, []).append(text)
        self.last_sent[ws] = text
        # a send that lands grows the transcript, which is what an honest surface does
        self.sizes[ws] = self.sizes.get(ws, 0) + len(text)
        # ⛔ AND IT APPEARS ON THE PANE (round 4, #4046 P0). The question arm reads the PANE back, so a
        # fake that recorded only `last_sent` would model a surface whose screen never shows what it
        # typed — i.e. a surface that cannot be verified at all.
        self.screens[ws] = (self.screens.get(ws, "") + "\n" + text).strip()
        return True

    def transcript_size(self, ws):
        return self.sizes.get(ws)

    def screen_tail(self, ws, lines=40):
        if self.screen_unreadable:
            return None
        return self.screens.get(ws)


def leg_user_question_end_to_end() -> None:
    print("\n── USER-QUESTION END-TO-END — a synthetic asking lane, routed and answered ──")
    # The lane asked the owner in its own pane and never posted a labelled comment, so the OLD guard
    # (`turn-end.py`'s `lanes_with_open_question`, which reads the `owner-decision` LABEL) cannot see
    # it. It reads WIP-IDLE and used to receive "CONTINUE IT".
    e = ev(lane="lane-7", last_text="Detection is landed.\n\nShould I build the router next, or "
                                     "wait for your ruling on the precedence?",
           lane_verdict="WIP-IDLE", steerable=True)
    r = triage.route(e)
    eq("the synthetic lane is classified user-question", r.route, "user-question")

    surface = FakeSurface(spaces=[{"id": "ws_owner", "name": "lane-7", "index": 3}],
                          screens={"ws_new_1": "composer ready"})
    proof = triage_arms.execute(r, e, surface, ws="ws_owner")

    ok("the arm verified its effect at the artifact", proof.verified, proof.detail)
    eq("the proof names the question-lane artifact", proof.proof, "question-lane-ack")
    qws = proof.artifact.get("question_ws")
    ok("a question workspace was resolved/created", bool(qws), repr(proof.artifact))
    eq("it sits in the cmux LEFT-HAND panel (index 0)",
       [sp["index"] for sp in surface.spaces if sp["id"] == qws], [0])

    brief = (surface.sent.get(qws) or [""])[0]
    ok("the brief carries the research mandate", "RESEARCH FIRST" in brief, brief[:120])
    ok("the brief carries the contradiction test", "CONTRADICTION TEST" in brief, brief[:120])
    for part in ("context", "options", "analysis", "recommendation"):
        ok("the brief carries the protocol part %r" % part, part in brief.lower())
    ok("the brief names the owning lane", "lane-7" in brief)

    # ⛔ THE POINT OF THE WHOLE ISSUE: the owning lane receives NOTHING from this arm. In particular
    # no "continue" — a question reported as idle is what tells a lane to proceed on a premise the
    # owner has not decided.
    ok("the OWNING lane received nothing at all", "ws_owner" not in surface.sent,
       repr(surface.sent.get("ws_owner")))
    ok("the OWNING lane certainly received no 'continue'",
       not any("continue" in t.lower() for t in surface.sent.get("ws_owner", [])))
    eq("the artifact records that the owning lane was not messaged",
       proof.artifact.get("owner_lane_sent_anything"), False)

    # and the answer comes back the other way: the question lane is told to post the decision back.
    ok("the brief tells the question lane to answer the waiting lane",
       "answer" in brief.lower() or "resume" in brief.lower())

    # ⛔ THE PROOF MUST BE ABLE TO FAIL THE WAY IT CLAIMS TO (round 4, #4046 P0). The first version
    # read `move_workspace`'s RETURN CODE and the text the surface itself passed to `send`, so neither
    # half could fail for the reason the proof exists. Measured before this leg: deleting the `moved`
    # term from the predicate left the suite at its exact baseline. These three are the failures it
    # now catches, and each one is INVISIBLE to a send/rc reading.
    for label, bad in (
        ("a move that reports success but leaves the lane at index 3",
         FakeSurface(spaces=[{"id": "ws_owner", "name": "lane-7", "index": 3}],
                     screens={"ws_new_1": "ready"}, move_ignored=True)),
        ("a surface whose pane cannot be read", FakeSurface(
            spaces=[{"id": "ws_owner", "name": "lane-7", "index": 3}], screen_unreadable=True)),
    ):
        pb = triage_arms.execute(r, e, bad, ws="ws_owner", nap=lambda _s: None)
        ok("NOT verified: %s" % label, not pb.verified, pb.detail)
    empty = FakeSurface(spaces=[{"id": "ws_owner", "name": "lane-7", "index": 3}],
                        screens={"ws_new_1": "composer ready"})
    # a pane that shows SOMETHING ELSE is a transport that did not deliver the mandate
    empty.send = lambda ws, text: (empty.sent.setdefault(ws, []).append(text)
                                   or empty.last_sent.__setitem__(ws, text) or True)
    pb = triage_arms.execute(r, e, empty, ws="ws_owner", nap=lambda _s: None)
    ok("NOT verified when the pane shows no mandate at all", not pb.verified, pb.detail)
    # and the owner-message fact is DERIVED, so it can read True (round 4, #4046 P1)
    noisy = FakeSurface(spaces=[{"id": "ws_owner", "name": "lane-7", "index": 3}],
                        screens={"ws_new_1": "ready"})
    pm = triage_arms.execute(r, e, noisy, ws="ws_owner", nap=lambda _s: None)
    ok("the record says the owning lane was not messaged", pm.verified)
    eq("…and that field is False when nothing was sent to it",
       pm.artifact.get("owner_lane_sent_anything"), False)
    noisy_owner = FakeSurface(spaces=[{"id": "ws_owner", "name": "lane-7", "index": 3}],
                              screens={"ws_new_1": "ready"})
    noisy_owner.send("ws_owner", "continue")
    pn = triage_arms.execute(r, e, noisy_owner, ws="ws_owner", nap=lambda _s: None)
    eq("…and TRUE the moment anything is sent to the owning lane",
       pn.artifact.get("owner_lane_sent_anything"), True)


def leg_arm_continue_proves_resumption() -> None:
    print("\n── IDLE-CONTINUE — the arm proves resumption, and never marks BUSY unproven ──")
    e = ev(lane="lane-2", lane_verdict="WIP-IDLE")
    r = triage.route(e)
    eq("a clean idle lane routes idle-continue", r.route, "idle-continue")

    growing = FakeSurface(sizes={"ws_a": 100})
    p = triage_arms.execute(r, e, growing, ws="ws_a")
    ok("a lane that GREW is verified", p.verified, p.detail)
    ok("the proof is the byte delta, not the send", "100 ->" in p.detail, p.detail)

    frozen = FakeSurface(sizes={"ws_b": 100})
    frozen.send = lambda ws, text: (frozen.sent.setdefault(ws, []).append(text) or True)  # no growth
    p2 = triage_arms.execute(r, e, frozen, ws="ws_b")
    ok("a lane that did NOT grow is NOT verified", not p2.verified, p2.detail)
    ok("…and the detail says escalate, not BUSY", "escalate" in p2.detail, p2.detail)
    ok("…and it still records that a send happened (so it is visible)", p2.sent)

    blind = FakeSurface()
    p3 = triage_arms.execute(r, e, blind, ws="ws_c")
    ok("no readable transcript before the send => nothing is sent", not p3.sent, p3.detail)
    ok("…and it is not verified", not p3.verified)


def leg_arm_wedged_remedies() -> None:
    print("\n── WEDGED ARMS — each remedy produces its own artifact, none sends 'continue' ──")
    # tool-in-flight and wedged-unverified execute NOTHING and must say so
    for subcase, want in (("tool-in-flight", "wait"), ("wedged-unverified", "inspect")):
        e = (ev(lane_verdict="LONG-TOOL", tool_in_flight=True, tool_budget_open=True, turn=TURN_OPEN)
             if subcase == "tool-in-flight"
             else ev(lane_verdict="WEDGED", turn=TURN_ENDED))
        r = triage.route(e)
        eq("%s: subcase" % subcase, r.subcase, subcase)
        p = triage_arms.execute(r, e, FakeSurface(), ws="ws_x")
        eq("%s: action" % subcase, p.action, want)
        ok("%s: nothing was sent" % subcase, not p.sent)
        ok("%s: the reading is the artifact" % subcase, p.verified and p.proof == "written-reading")

    # boot-prompt: reuses the dispatcher, and the proof is the PANE
    e = ev(lane_verdict="DONE-IDLE", boot_prompt=True)
    r = triage.route(e)
    eq("boot-prompt: subcase", r.subcase, "boot-prompt")
    surf = FakeSurface(screens={"ws_bp": "composer ready, pi footer"})
    p = triage_arms.execute(r, e, surf, ws="ws_bp", dispatch=lambda ws, lane: 0)
    ok("boot-prompt: verified once the pane stops showing the prompt", p.verified, p.detail)
    still = FakeSurface(screens={"ws_bp": "Press any key to continue..."})
    p2 = triage_arms.execute(r, e, still, ws="ws_bp", dispatch=lambda ws, lane: 0)
    ok("boot-prompt: NOT verified while the prompt is still on the pane", not p2.verified, p2.detail)
    # ⛔ THE FALSE NEGATIVE THE PRESENCE TEST PRODUCED (round 4, #4046 P1). pi renders inline, so a
    # SATISFIED prompt stays in the scrollback above the input box for the life of the session
    # (`cmux_dispatch.py:723-757`, "observed live: 62 lines from the end of an 80-line capture on a
    # healthy pane"). A presence test therefore reported "the prompt is STILL on the pane" for every
    # REPAIRED lane, forever — the arm could never verify the repair it exists to verify.
    healthy = FakeSurface(screens={"ws_bp": "Press any key to continue...\n"
                                           "booted in 1.2s\n$ /home/cmux \n42.0%/700k (auto)"})
    p3 = triage_arms.execute(r, e, healthy, ws="ws_bp", dispatch=lambda ws, lane: 0)
    ok("boot-prompt: a HEALTHY pane with the marker in scrollback verifies", p3.verified, p3.detail)
    ok("…and the record says the prompt is gone", p3.artifact.get("boot_prompt") is False,
       repr(p3.artifact))
    # the stale-footer case the same docstring names: the bar ABOVE the marker is a dead session's
    dead = FakeSurface(screens={"ws_bp": "42.0%/700k (auto)\nPress any key to continue..."})
    p4 = triage_arms.execute(r, e, dead, ws="ws_bp", dispatch=lambda ws, lane: 0)
    ok("boot-prompt: a bar ABOVE the marker is still a block", not p4.verified, p4.detail)
    # ⛔ THE UNKNOWN-PERCENTAGE FORM (round 6, #4046 P2). `?/700k` is what the stats line shows right
    # after boot — exactly when this arm reads it — and `cmux_dispatch.READY_RE` accepts it. Reverting
    # `_STATS_RE` to percentage-only left the suite green before this fixture.
    nopercent = FakeSurface(screens={"ws_bp": "Press any key to continue\n?/700k (auto)\n> "})
    p6 = triage_arms.execute(r, e, nopercent, ws="ws_bp", dispatch=lambda ws, lane: 0)
    ok("boot-prompt: a stats line with an UNKNOWN percentage still reads as repaired", p6.verified,
       p6.detail)
    unread = FakeSurface(screen_unreadable=True)
    p5 = triage_arms.execute(r, e, unread, ws="ws_bp", dispatch=lambda ws, lane: 0)
    ok("boot-prompt: an unreadable pane is NOT verified", not p5.verified, p5.detail)

    tmpd = tempfile.mkdtemp(prefix="triage-test-handoff-")
    # child subcases: a named hand-off, never a kill from this arm
    # ⛔ THE FIXTURE IS THE PRODUCER'S OWN SHAPE (round 3, #4046 P1). `lane-status.py:1586-1590`
    # emits `call_id / ts / age / abandoned / cwd / task / agent` — the earlier fixture invented
    # `{"pid": 4242}` and so certified a hand-off the real record could never satisfy.
    REAL_CHILD = {"call_id": "c-4242", "ts": 1, "age": 12, "abandoned": False,
                  "cwd": "/tmp/wt", "task": "build the thing", "agent": "worker"}
    for subcase, verdict in (("child-stuck", "CHILD-STUCK"), ("child-overdue", "CHILD-OVERDUE")):
        e = ev(lane_verdict=verdict)
        r = triage.route(e)
        eq("%s: subcase" % subcase, r.subcase, subcase)
        p = triage_arms.execute(r, e, FakeSurface(), ws="ws_c", child=REAL_CHILD,
                                state_dir=tmpd)
        eq("%s: action" % subcase, p.action, "repair-child")
        ok("%s: a REAL lane-status child record VERIFIES the hand-off" % subcase, p.verified,
           p.detail)
        ok("%s: the child is NAMED in the artifact" % subcase,
           p.artifact["child"].get("call_id") == "c-4242")
        ok("%s: nothing was killed and nothing was typed" % subcase, not p.sent)
        unnamed = triage_arms.execute(r, e, FakeSurface(), ws="ws_c", child={},
                                     state_dir=tmpd)
        ok("%s: an unread child is not verified and not killed" % subcase, not unnamed.verified)
    # ⛔ A STATE WORD IS NOT A RECORD (round 3, #4046 P1): with no child dict, the arm must NOT
    # verify off `child_state` — that was a false PASS on a proof that was never read.
    e_stuck = ev(lane_verdict="CHILD-STUCK", child_state="stuck")
    p_state = triage_arms.execute(triage.route(e_stuck), e_stuck, FakeSurface(), ws="ws_c",
                                  state_dir=tmpd)
    ok("child-stuck with ONLY a state word is NOT verified", not p_state.verified, p_state.detail)
    ok("…and names no fabricated child", p_state.artifact.get("child") == {},
       repr(p_state.artifact))
    # ⛔ AND THE DOOR THE SYNTHESIS USED TO WALK THROUGH (round 4, author fix). Deleting the
    # synthesis from `execute()` closed the production path, but the ARM still accepted `name` /
    # `pid` / `sid` / `label` — keys `lane-status.py` never emits — so `arm_child("L", {"name":
    # "stuck"}).verified` was still True: a caller could certify a "hand-off" of a dict no producer
    # can produce. Measured before this leg: True, and it PASSED through every other assertion here.
    for fake in ({"name": "stuck"}, {"pid": 4242}, {"sid": "s"}, {"label": "kid"},
                 {"pid": 4242, "label": "kid", "name": "kid"}):
        ok("a child dict keyed only on a key no producer emits is NOT verified: %r" % (fake,),
           not triage_arms.arm_child("L", fake, state_dir=tmpd).verified,
           triage_arms.arm_child("L", fake, state_dir=tmpd).detail)
    # ⛔ AND THE WRITTEN RECORD IS THE ARTIFACT (round 4, #4046 P0). Before this leg the arm returned
    # `verified=True` off a field's presence with nothing written and the input dict untouched — the
    # claim this module exists to refuse. The file must exist, carry the child, and be RE-READ.
    hp = triage_arms.handoff_path(tmpd, "L")
    ok("the hand-off record is a REAL file on disk", os.path.exists(hp), hp)
    p_nostate = triage_arms.arm_child("L", REAL_CHILD)
    ok("a hand-off with nowhere to write is NOT verified", not p_nostate.verified, p_nostate.detail)
    # ⛔ AND THE RE-READ MUST BE THE THING THAT DECIDES (round 5, #4046 P2). Mutation-measured at
    # 502fa170a: replacing the comparison with `True` left the suite GREEN, so the arm's documented
    # proof had no discriminating leg. A record on disk carrying a DIFFERENT child must not verify.
    # ⛔ A RECORD THAT WAS READ BUT SAYS SOMETHING ELSE (round 5, #4046 P2). Mutation-measured at
    # 502fa170a: replacing the comparison with `True` left the suite GREEN — the arm's documented
    # proof had no discriminating leg. The failing write below is not enough (it fails before the
    # comparison); the comparison itself needs a readable record carrying a DIFFERENT child. A torn
    # write is exactly that shape, so `os.replace` is made a no-op for one call, leaving the previous
    # record — a different child — where the arm expects its own.
    stale = {"call_id": "c-OTHER", "task": "a different child"}
    with open(hp, "w") as fh:
        json.dump({"kind": "child-handoff", "lane": "L", "child": stale}, fh)
    real_replace = os.replace

    def _torn(src, dst, *a, **kw):     # the write happened, the RENAME did not
        try:
            os.unlink(src)
        except OSError:
            pass

    os.replace = _torn
    try:
        p_torn = triage_arms.arm_child("L", REAL_CHILD, state_dir=tmpd)
    finally:
        os.replace = real_replace
    ok("a readable record carrying a DIFFERENT child is NOT verified", not p_torn.verified,
       p_torn.detail)
    ok("…and the artifact shows what was actually read back",
       (p_torn.artifact.get("read_back") or {}).get("call_id") == "c-OTHER",
       repr(p_torn.artifact.get("read_back")))
    # (and the write itself failing must not raise: a directory where the record belongs)
    os.unlink(hp)
    os.makedirs(hp)
    p_dir = triage_arms.arm_child("L", REAL_CHILD, state_dir=tmpd)
    ok("a record that cannot be RE-READ is not verified", not p_dir.verified, p_dir.detail)
    os.rmdir(hp)
    p_ok = triage_arms.arm_child("L", REAL_CHILD, state_dir=tmpd)
    ok("…and the same call verifies once the record can be written and read back", p_ok.verified,
       p_ok.detail)
    eq("the artifact carries the child it re-read", p_ok.artifact["read_back"]["call_id"],
       "c-4242")

    # rerun: lane-relaunch.py's own exit code IS the proof
    e = ev(lane_verdict="WEDGED", turn=TURN_OPEN)
    r = triage.route(e)
    eq("open-turn-never-closes: subcase", r.subcase, "open-turn-never-closes")
    p = triage_arms.execute(r, e, FakeSurface(), ws="ws_r", relaunch=lambda ws: 0)
    ok("rerun: CONFIRMED (rc 0) verifies", p.verified, p.detail)
    for rc, why in ((3, "REFUSED"), (4, "UNCONFIRMED"), (5, "DRY-RUN"), (1, "ERROR")):
        p = triage_arms.execute(r, e, FakeSurface(), ws="ws_r", relaunch=lambda ws, _rc=rc: _rc)
        ok("rerun: rc=%d is not verified and says %s" % (rc, why),
           (not p.verified) and why in p.detail, p.detail)


def leg_records() -> None:
    print("\n── RECORDS — the decision and its proof are durable, and 'verified' is carried ──")
    import json as _json
    import tempfile
    e = ev(lane="lane-9", lane_verdict="WIP-IDLE")
    r = triage.route(e)
    surf = FakeSurface(sizes={"ws_a": 10})
    p = triage_arms.execute(r, e, surf, ws="ws_a")
    with tempfile.TemporaryDirectory() as td:
        path = triage_arms.write_record(td, "lane-9", r, p)
        with open(path) as fh:
            row = _json.load(fh)
    eq("the record carries the route", row["route"], "idle-continue")
    eq("the record carries the proof name", row["proof"], "transcript-growth")
    eq("the record carries whether the effect was VERIFIED", row["result"]["verified"], True)
    ok("the record carries the evidence that decided it", bool(row["reason"]))


def leg_wiring() -> None:
    print("\n── WIRING — the router is CONSUMED, and its consumer cannot lose it silently ──")
    # `may_continue` is the one predicate a nudger gates on. Pin both directions, because an arm
    # that never fires satisfies "never nudges a question" just as well as a correct one.
    may, r = triage.may_continue(ev(last_text="Should I merge?"))
    ok("a question may NOT be continued", not may)
    eq("…and the route says why", r.route, "user-question")
    may, r = triage.may_continue(ev(last_text="Landing it now."))
    ok("a clean idle lane MAY be continued", may)
    may, _ = triage.may_continue(ev(last_text="Landing it now.", steerable=False))
    ok("a `pi -p` lane may NOT be continued even when it looks idle", not may)
    may, _ = triage.may_continue(ev(last_text="", lane_verdict="DONE-IDLE"))
    ok("an unread tail may NOT be continued", not may)
    # ⛔ AND THE POSITIVE PATH MUST EXIST (fresh-context review, #4046 P0). The first version's
    # steerability probe answered `None` for every ordinary lane — a live `pi` has argv exactly `pi`,
    # so `argv-candidates` finds nothing — and since a `None` refuses the send, `turn-end.py` nudged
    # NOBODY. That is a fleet-wide nudging stop dressed as a refusal, so it gets its own assertion.
    eq("an interactive lane (session bound to a workspace) IS steerable",
       triage.steerable(None, ws="ws_x", session_path="/tmp/session.jsonl"), True)
    eq("no session and no workspace is UNKNOWN, never steerable",
       triage.steerable(None), None)

    # The farm declaration: turn-end.py is farmed FLAT and imports `$SCRIPTS/fleet/triage.py`, so a
    # farm entry that names only one of the pair ships a router whose arms nobody has.
    repo = os.path.dirname(HERE)
    import importlib.util as _ilu
    setup = os.path.join(os.path.dirname(repo), "pi-bootstrap", "setup.sh")
    if os.path.exists(setup):
        import re as _re
        blob = open(setup, encoding="utf-8", errors="replace").read()
        # ⛔ LINE-ANCHORED, EXACTLY AS `test-setup-no-nesting.sh` DERIVES IT
        # (`sed -n 's/^fleet_tools=(\(.*\))$/\1/p'`). A looser search matched the PROSE in the comment
        # that explains this rule, i.e. the assertion would have passed on a comment and failed on the
        # array — measured, and the reason this leg reads the array the way its real consumer does.
        m = _re.search(r"^fleet_tools=\((.*)\)$", blob, _re.M)
        decl = m.group(1) if m else ""
        ok("the fleet_tools array is readable by the no-nesting gate's own derivation", bool(decl),
           "a wrapped or commented array reads as EMPTY there (#1899)")
        for needed in ("triage.py", "triage_arms.py"):
            ok("pi-bootstrap farms %s (turn-end.py imports it from $SCRIPTS/fleet)" % needed,
               needed in decl.split(), decl[:140])
    else:
        ok("pi-bootstrap/setup.sh is present to declare the farm", False, setup)

    # The consumer: turn-end.py must actually CALL the predicate AND gate its `continue` on it. A
    # guard that exists but is not consulted — or is consulted and then ignored — is the
    # inert-enforcer class, and both look identical to a working one in review (fresh-context review,
    # #4046 P2: `"may_continue(" in blob` was green for `if False: may_continue(...)`).
    te = os.path.join(os.path.dirname(repo), "scripts", "turn-end.py")
    if os.path.exists(te):
        blob = open(te, encoding="utf-8", errors="replace").read()
        # The gate is the extracted seam (`route_gate`), and the LOOP must call it and gate a real
        # `continue` on the answer. Both halves are asserted: the seam alone would be a function
        # nobody calls, and the call site alone would not prove the answer is consulted.
        i = blob.find("_may, _route = route_gate(r, f)")
        ok("turn-end.py's loop calls the router gate", i != -1)
        window = blob[i:i + 500] if i != -1 else ""
        ok("…and GATES a `continue` on the answer", "if not _may:" in window and "continue" in window,
           window[-200:])
        j = blob.find("return _triage.may_continue(ev)")
        ok("…and route_gate() is where may_continue() is asked", j != -1)
        ok("turn-end.py says so when the router is absent",
           "router unavailable" in blob, "a silent degrade looks like a quiet fleet")
        # ⛔ THE ARGUMENTS ARE HALF THE GATE (round 3, #4046 P2). The P0 fixed in 228699917 WAS a wrong
        # call to `steerable()` at this very call site, and this leg was green through it: the guard
        # body was correct, the evidence handed to it was not. Pin the evidence too.
        j = blob.find("_triage.steerable(")
        call = blob[j:j + 200] if j != -1 else ""
        for frag in ("sid", "ws=", "session_path="):
            ok("turn-end.py passes %r to the steerability probe" % frag, frag in call, call[:160])
    else:
        ok("scripts/turn-end.py is present to be wired", False, te)

    # ⛔ ONE PAYLOAD PER ROUTE (fresh-context review, #4046 P1): the boot-prompt repair must NOT be
    # handed the question-lane mandate.
    q = triage_arms.payload_for(triage.route(ev(last_text="Should I merge?")), ev(last_text="Ask"))
    b = triage_arms.payload_for(triage.route(ev(lane_verdict="DONE-IDLE", boot_prompt=True)), ev())
    ok("the question arm's payload carries the mandate", not triage_arms.mandate_missing(q))
    ok("the BOOT-PROMPT payload carries NO mandate", bool(triage_arms.mandate_missing(b)), b[:90])
    ok("the two payloads differ", q != b)

    # ⛔ AND THE PRODUCTION GATE ITSELF (round 3, #4046 P2). While `may_continue` lived inline in
    # `turn-end.py`'s loop, its correctness was pinned but the CONSUMER that suppresses the nudge was
    # not, because `main()` shells out to lane-status and cannot be driven hermetically. `route_gate()`
    # is the extracted seam, and these legs drive it with real rows.
    te2 = os.path.join(os.path.dirname(repo), "scripts", "turn-end.py")
    spec2 = _ilu.spec_from_file_location("turn_end_under_test", te2)
    te_mod = _ilu.module_from_spec(spec2)
    spec2.loader.exec_module(te_mod)
    ok("turn-end.py's gate is present and wired to the real router",
       callable(getattr(te_mod, "route_gate", None)) and te_mod._triage is not None)
    import tempfile as _tf
    with _tf.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
        for rec in (
            {"type": "message", "message": {"role": "user", "content": "go"}},
            {"type": "message", "message": {"role": "assistant", "stopReason": "stop",
                                            "content": "Should I merge?\n\nBlocked on your decision."}},
        ):
            fh.write(__import__("json").dumps(rec) + "\n")
        qpath = fh.name
    with _tf.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
        for rec in (
            {"type": "message", "message": {"role": "user", "content": "go"}},
            {"type": "message", "message": {"role": "assistant", "stopReason": "stop",
                                            "content": "Landed it; tests green."}},
        ):
            fh.write(__import__("json").dumps(rec) + "\n")
        npath = fh.name
    row_q = {"lane": "L", "verdict": "WIP-IDLE", "sid": None, "ws": "ws", "cwd": "/tmp"}
    may_q, route_q = te_mod.route_gate(row_q, qpath)
    may_n, route_n = te_mod.route_gate(row_q, npath)
    ok("the REAL gate refuses a lane whose tail asks the owner", not may_q, route_q.reason)
    eq("…and names it a user-question", route_q.route, "user-question")
    ok("the REAL gate allows a lane whose tail does not", may_n, route_n.reason)
    eq("…and names it idle-continue", route_n.route, "idle-continue")
    os.unlink(qpath)
    os.unlink(npath)

    # ⛔ THE BRANCH, NOT JUST THE PREDICATE (round 4, #4046 P1). Suppressing the nudge without routing
    # the question is the defect: every arm was reachable only from the CLI and a fixture, so the
    # issue's second requirement was delivered by no running code. The loop now calls THIS, and the
    # arm is invoked for a question route and for nothing else.
    calls = []
    te_mod.log = lambda msg: calls.append(msg)
    te_mod._apply_question_route = lambda lane: calls.append("APPLIED:" + lane)
    route_q = triage.route(ev(lane="lane-q", last_text="Should I merge?",
                              lane_verdict="WIP-IDLE", steerable=True))
    te_mod.suppress_and_route("lane-q", route_q)
    ok("a user-question route APPLIES the arms (creates the question lane)",
       "APPLIED:lane-q" in calls, repr(calls))
    ok("…and the skip is logged with its reason", any(c.startswith("SKIP lane-q") for c in calls),
       repr(calls))
    calls.clear()
    te_mod.suppress_and_route("lane-w", triage.route(ev(lane="lane-w", lane_verdict="CHILD-STUCK",
                                                        steerable=True)))
    ok("a WEDGED route does NOT reach the question arms", "APPLIED:lane-w" not in calls, repr(calls))

    # ⛔ THE BATCH MUST CARRY THE FULL ROW (round 6, #4046 P0). The first version appended
    # `{"lane": lane}`, and the CLI rebuilds `Evidence` from what it is handed — so every batched lane
    # arrived with no `sid`/`ws`/`verdict`, re-decided to `none`/`none`, and was logged as
    # `verified=true` for an action nothing took. Measured here through the real `_apply_question_routes`.
    te_mod.SCRIPTS = os.path.join(os.path.dirname(repo), "scripts")
    te_mod.STATE = tempfile.mkdtemp(prefix="te-batch-state-")
    captured = {}

    class _P:
        returncode = 0
        stdout = "[]"
        stderr = ""

    real_run = te_mod.subprocess.run

    def _fake_run(argv, **kw):
        if "--stdin" in argv:
            with open(argv[argv.index("--stdin") + 1]) as fh:
                captured["payload"] = json.load(fh)
            captured["argv"] = list(argv)
        return _P()

    logs = []
    te_mod.subprocess.run = _fake_run
    te_mod.log = lambda m: logs.append(m)
    try:
        row_full = {"lane": "lane-7", "verdict": "WIP-IDLE", "sid": "s1", "cwd": "/tmp",
                    "ws": "w1", "stale_s": 9999}
        pend = []
        te_mod.suppress_and_route("lane-7", route_q, pending=pend, row=row_full)
        eq("the batch collects ONE row for the asking lane", len(pend), 1)
        te_mod._apply_question_routes(pend)
        got = (captured.get("payload") or [{}])[0]
        ok("the payload carries the row's OWN evidence keys (a lane name alone re-decides to `none`)",
           all(k in got for k in ("verdict", "sid", "cwd", "ws")), repr(got))
        ok("…and the CLI is told to apply ONLY question routes (a `send-continue` arm would poll "
           "past the parent's budget)", "--only-route" in (captured.get("argv") or []),
           repr(captured.get("argv")))
        # the cap must be VISIBLE, or the 4th+ asking lane starves silently
        logs.clear()
        te_mod._apply_question_routes([{"lane": "lane-%d" % i, "verdict": "WIP-IDLE"}
                                       for i in range(1, 6)])
        ok("asking lanes beyond the cap are LOGGED as deferred, not dropped",
           any("deferred to next tick" in m and "lane-4" in m for m in logs), repr(logs))
    finally:
        te_mod.subprocess.run = real_run
        te_mod.log = lambda msg: calls.append(msg)

    # ⛔ THE FARM IS LOAD-BEARING, SO THE TEST MUST NOT READ THE CHECKOUT (round 4, #4046 P2). This
    # leg used to assert `te_mod._triage is not None` in THIS process, where `triage` was already
    # imported from `tools/fleet` — so a farm entry that no longer shipped `triage.py` left the suite
    # green while a farmed box (no checkout) had `_ROUTER = ModuleNotFoundError` and nudged nobody.
    # Measured in a fresh interpreter before this leg: `_triage = None`, suite PASS.
    import shutil as _sh
    import subprocess as _sp
    # ⛔ THE FARM IS SIMULATED THROUGH `HOME`, because `turn-end.py:99` resolves `SCRIPTS` as
    # `$HOME/.pi/agent/scripts` and takes NO override. A test that sets `SCRIPTS` in the env would be
    # testing an environment variable the consumer never reads — green while the box it models is
    # broken. The leg therefore builds a throwaway HOME with and without the farmed fleet dir.
    farm = _tf.mkdtemp(prefix="triage-farm-")
    fleetdir = os.path.join(farm, ".pi", "agent", "scripts", "fleet")
    os.makedirs(fleetdir, exist_ok=True)
    _probe = ("import importlib.util, sys\n"
              "spec = importlib.util.spec_from_file_location('te', %r)\n"
              "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
              "print('TRIAGE', m._triage is not None)\n"
              "print('ROUTER', repr(m._ROUTER))\n" % (te2,))
    empty = _sp.run([sys.executable, "-c", _probe], capture_output=True, text=True,
                    env=dict(os.environ, HOME=farm), cwd="/tmp")
    ok("with an EMPTY farm the router is absent AND says so",
       "TRIAGE False" in empty.stdout and "ModuleNotFoundError" in empty.stdout,
       (empty.stdout + empty.stderr)[-300:])
    for name in ("triage.py", "triage_arms.py", "liveness.py"):
        _sh.copy(os.path.join(os.path.dirname(repo), "tools", "fleet", name),
                 os.path.join(fleetdir, name))
    full = _sp.run([sys.executable, "-c", _probe], capture_output=True, text=True,
                   env=dict(os.environ, HOME=farm), cwd="/tmp")
    ok("with the farmed router present the consumer LOADS it (the farm line is load-bearing)",
       "TRIAGE True" in full.stdout, (full.stdout + full.stderr)[-300:])
    # and the farm itself must name every file the consumer needs, or the box above is production
    setup = open(os.path.join(os.path.dirname(repo), "pi-bootstrap", "setup.sh")).read()
    srcs = re.search(r"(?m)^fleet_srcs=\(([^)]*)\)", setup)
    tools = re.search(r"(?m)^fleet_tools=\(([^)]*)\)", setup)
    ok("the farm ships triage.py + triage_arms.py",
       "triage.py" in (tools.group(1) if tools else "")
       and "triage_arms.py" in (tools.group(1) if tools else ""), "fleet_tools missing the pair")
    ok("the farm ships the CLI that APPLIES a route (lane-route.py)",
       "lane-route.py" in (srcs.group(1) if srcs else ""),
       "lane-route.py missing from fleet_srcs — the arms would have no production caller")

    # ⛔ THE `tool-in-flight` SUBCASE MUST BE REACHABLE FROM THE REAL ACQUIRER (fresh-context review,
    # #4046 P1). `lane-status.py` emits `tool` as a DICT (name/timeout/age); the first version read
    # OBJECT attributes, so the subcase was permanently unreachable in production while its fixture
    # passed on hand-built evidence.
    sys.path.insert(0, os.path.join(os.path.dirname(repo), "scripts"))
    spec = _ilu.spec_from_file_location("lane_route_under_test",
                                        os.path.join(os.path.dirname(repo), "scripts",
                                                     "lane-route.py"))
    lr = _ilu.module_from_spec(spec)
    spec.loader.exec_module(lr)
    row = {"lane": "L", "verdict": "LONG-TOOL", "sid": None, "ws": "ws", "cwd": "/tmp",
           "tool": {"name": "bash", "timeout": 3000, "age": 500}}
    e2, _ = lr.evidence_for(row, read_text=False)
    ok("a declared tool budget inside its timeout reads as tool_in_flight", e2.tool_in_flight)
    ok("…and its budget reads as OPEN (age < declared timeout)", e2.tool_budget_open)
    eq("…so the route is the tool-in-flight subcase with the WAIT remedy",
       (triage.route(e2).subcase, triage.route(e2).action), ("tool-in-flight", "wait"))
    row2 = dict(row, tool={"name": "bash", "timeout": 60, "age": 5000})
    e3, _ = lr.evidence_for(row2, read_text=False)
    eq("a call PAST its declared budget is not 'inside its budget'", e3.tool_budget_open, False)
    eq("…but the budget WAS READ, which is different from unreadable", e3.tool_budget_read, True)
    eq("…so an overrun is routed to INSPECT, not parked at wait", triage.route(e3).action, "inspect")
    eq("a call with NO declared timeout is unread, not expired",
       lr.evidence_for(dict(row, tool={"name": "bash"}), read_text=False)[0].tool_budget_read, False)
    # and the model-retry producer must exist too
    ok("a rate-limit tail produces the model-retry signal",
       lr.evidence_for(dict(row, tool=None), read_text=False)[0].model_retry is False)
    eq("retry_signature recognises a rate-limit tail", triage.retry_signature("HTTP 429 rate limit, retrying in 30s"), True)
    eq("retry_signature does not fire on ordinary prose", triage.retry_signature("Merged the PR."), False)

    # ⛔ THE RETRY SIGNATURE'S OWN P0 (round 3, #4046): a bare `429` matched any number CONTAINING
    # those digits, and the branch was ungated, so a WORKING lane that merely mentioned a ticket routed
    # `wedged/model-retry` whose remedy is `rerun` — a relaunch of a lane that was working.
    for prose in ("Merged PR #14290 and verified all checks.",
                  "Closed issue #34290."):
        eq("retry_signature does NOT fire on %r" % prose[:34], triage.retry_signature(prose), False)
    # A sentence that mentions a 429 it FIXED still carries the word, so the signature may read it —
    # the guard that matters is that the ROUTE does not act on a lane that is working or has closed
    # its turn (asserted immediately below). A detector that had to be perfect here would be a second
    # judge of prose; the router's job is to refuse to LAUNCH on it.
    eq("a 429 mentioned in a fix report does not relaunch a WORKING lane",
       (triage.retry_signature("Fixed the 429 handling in the retry loop."),
        triage.route(ev(turn=TURN_OPEN, lane_verdict="WORKING", model_retry=True)).action),
       (True, "none"))
    for tail in ("HTTP 429 Too Many Requests — retrying.", "rate limit hit; retrying in 30s",
                 "provider error: upstream timeout"):
        eq("retry_signature DOES fire on %r" % tail[:34], triage.retry_signature(tail), True)

    # …and a genuine retry signature must not override a WORKING lane, nor a lane with no open turn.
    for verdict in triage.WORKING_VERDICTS:
        e_r = ev(turn=TURN_OPEN, last_text="HTTP 429 Too Many Requests — retrying.",
                 lane_verdict=verdict, model_retry=True)
        eq("a retry signature on a %s lane is NOT routed to model-retry" % verdict,
           triage.route(e_r).subcase != "model-retry", True)
    e_closed = ev(turn=TURN_ENDED, last_text="HTTP 429 Too Many Requests — retrying.",
                  lane_verdict="WEDGED", model_retry=True)
    ok("a retry signature with NO positively open turn is not a confirmed wedge",
       triage.route(e_closed).subcase != "model-retry", triage.route(e_closed).subcase)
    e_open = ev(turn=TURN_OPEN, last_text="HTTP 429 Too Many Requests — retrying.",
                lane_verdict="WEDGED", model_retry=True)
    eq("…and the positive control: open turn + retry tail IS the subcase",
       triage.route(e_open).subcase, "model-retry")


def leg_cli_apply() -> None:
    """`scripts/lane-route.py --apply`, driven END TO END with its REAL helpers (round 5, #4046 P0).

    ⛔ WHY THIS LEG EXISTS. The question arm was retrying the pane read with the CONTINUE arm's
    `poll` — a 3-argument resumption reader — so the first retry raised `TypeError` out of the arm and
    out of `lane-route.main()`, i.e. on the NORMAL case where the pane has not painted yet. The suite
    could not see it because every fixture passed a 1-arg stub: THE TEST CERTIFIED AN ARITY PRODUCTION
    NEVER SUPPLIED. So this leg drives `main()` itself, with the real `_make_poll`, `_make_dispatch`
    and `_make_relaunch` in place, a fake SURFACE, and a pane that gains the mandate on its second
    read (which forces the retry path). It also pins the dedupe: a prior UNVERIFIED route must be
    RETRIED, not replayed as `already-routed, verified: true`.
    """
    print("\n── CLI APPLY — the real `lane-route.py --apply`, retries and dedupe included ──")
    lr_path = os.path.join(os.path.dirname(os.path.dirname(HERE)), "scripts", "lane-route.py")
    import importlib.util as _ilu2
    spec = _ilu2.spec_from_file_location("lane_route_apply_under_test", lr_path)
    lr = _ilu2.module_from_spec(spec)
    spec.loader.exec_module(lr)

    state = tempfile.mkdtemp(prefix="triage-cli-state-")
    rows_file = os.path.join(state, "rows.json")

    class ReadingSurface(FakeSurface):
        """Fails the pane read until the SECOND attempt — the retry the arity bug killed."""

        def __init__(self, *a, **kw):
            super().__init__(*a, **kw)
            self.reads = 0

        def screen_tail(self, ws, lines=40):
            self.reads += 1
            return super().screen_tail(ws, lines) if self.reads >= 2 else ""

    def make_surface(sessions=None):
        return surf

    e = ev(lane="lane-cli", last_text="Should I merge, or hold?", lane_verdict="WIP-IDLE",
           steerable=True)
    surf = ReadingSurface(spaces=[{"id": "ws_owner", "name": "lane-cli", "index": 3}])
    saved = (lr.CmuxSurface, lr.evidence_for)
    lr.CmuxSurface = make_surface
    lr.evidence_for = lambda row, **kw: (e, {"ws": "ws_owner", "child": {}})
    # the retry sleeps a real second per attempt, and there are several ticks here
    nap_saved = triage_arms.time
    triage_arms.time = type("T", (), {"sleep": staticmethod(lambda _s: None)})()
    try:
        with open(rows_file, "w") as fh:
            json.dump([{"lane": "lane-cli"}], fh)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = lr.main(["--apply", "--json", "--stdin", rows_file, "--state", state])
        ok("--apply returns 0 with a pane that needed a RETRY (the poll-arity class)",
           rc == 0, out.getvalue()[-300:])
        rec = triage_arms.record_path(state, "lane-cli")
        ok("a record was written", os.path.exists(rec), rec)
        with open(rec) as fh:
            blob = json.load(fh)
        ok("the first read failed and the retry still verified the route",
           (blob.get("result") or {}).get("verified") is True, repr(blob.get("result"))[:300])
        ok("…and the arm ran the RETRY (the pane was read more than once)", surf.reads >= 2,
           "reads=%d" % surf.reads)

        # ⛔ AN UNVERIFIED PRIOR ROUTE MUST BE RETRIED (round 5, #4046 P1). Simulate the record a
        # FAILED send leaves: same route, same brief digest, verified false. The next tick must try
        # again rather than reporting `already-routed, verified: true` forever.
        with open(rec, "w") as fh:
            json.dump({"lane": "lane-cli", "route": "user-question",
                       "result": {"action": "route-to-question-lane", "verified": False,
                                  "artifact": (blob.get("result") or {}).get("artifact") or {}}}, fh)
        before = len(surf.sent.get(blob["result"]["artifact"]["question_ws"], []))
        with contextlib.redirect_stdout(io.StringIO()):
            lr.main(["--apply", "--json", "--stdin", rows_file, "--state", state])
        after = len(surf.sent.get(blob["result"]["artifact"]["question_ws"], []))
        ok("an UNVERIFIED prior route is RETRIED, not replayed as already-routed", after > before,
           "sends %d -> %d" % (before, after))

    # and once verified, the repeat is a no-op (the tick guard must still work)
        with contextlib.redirect_stdout(io.StringIO()):
            lr.main(["--apply", "--json", "--stdin", rows_file, "--state", state])
        resend = len(surf.sent.get(blob["result"]["artifact"]["question_ws"], []))
        with contextlib.redirect_stdout(io.StringIO()):
            lr.main(["--apply", "--json", "--stdin", rows_file, "--state", state])
        ok("…while a VERIFIED route is not typed twice", 
           len(surf.sent.get(blob["result"]["artifact"]["question_ws"], [])) == resend,
           "sends %d -> %d" % (resend,
                               len(surf.sent.get(blob["result"]["artifact"]["question_ws"], []))))
        # the shared-payload-file class: nothing may be left behind under the state dir
        leftovers = ([n for n in os.listdir(os.path.join(state, "lane-route"))
                      if n.startswith("payload") or n.endswith(".tmp")]
                     if os.path.isdir(os.path.join(state, "lane-route")) else [])
        eq("no payload/temp file is left behind after the run", leftovers, [])
    finally:
        lr.CmuxSurface, lr.evidence_for = saved
        triage_arms.time = nap_saved


def leg_surface_terminal() -> None:
    """The workspace→TERMINAL join, against the REAL `cmux tree --json` shape (round 6, #4046 P0).

    ⛔ WHY. `workspaces[]` on this build is `{focused,id,index,name,session_id}` — it has NO terminal
    field — so the first implementation of `_terminal_for` answered `None` for every workspace on the
    box. `screen_tail` was therefore permanently unreadable: the question arm could never verify, the
    dedupe never armed (the same brief re-sent every tick), and the `boot-prompt` subcase was
    unreachable from the only acquirer. Mutation-measured: `_terminal_for → None` left the suite at
    PASS, so this leg is the thing that makes the join a gate.

    The join that exists: workspaces[].id → screens[].workspace_id → layout.active_pane_id →
    tabs[].pane_id → tabs[].content_id (content_kind == "terminal").
    """
    print("\n── SURFACE — the workspace→terminal join and what a failed read means ──")
    lr_path = os.path.join(os.path.dirname(os.path.dirname(HERE)), "scripts", "lane-route.py")
    import importlib.util as _ilu3
    spec = _ilu3.spec_from_file_location("lane_route_surface_under_test", lr_path)
    lr = _ilu3.module_from_spec(spec)
    spec.loader.exec_module(lr)

    tree = {"workspaces": [{"focused": False, "id": "ws_l9", "index": 0, "name": "wt-lane-9",
                            "session_id": "session_x"}],
            "screens": [{"id": "s9", "workspace_id": "ws_l9",
                         "layout": {"active_pane_id": "pane_l9",
                                    "root": {"kind": "leaf", "pane_id": "pane_l9",
                                             "active_tab_id": "tab_l9",
                                             "tab_ids": ["tab_l9"]}}}],
            "tabs": [{"id": "tab_b9", "pane_id": "pane_l9", "content_kind": "browser",
                      "content_id": "br_l9"},
                     {"id": "tab_l9", "pane_id": "pane_l9", "content_kind": "terminal",
                      "content_id": "term_l9"}],
            "terminals": [{"id": "term_l9"}]}
    calls = []

    def _fake_cmux(argv, timeout=45):
        calls.append(list(argv))
        if argv[:2] == ["tree", "--json"]:
            return 0, json.dumps(tree), ""
        if argv[:1] == ["read-screen"] and "--terminal" in argv:
            return 0, "pi footer\n> ", ""
        return 2, "", "usage"

    real = lr._cmux
    try:
        lr._cmux = _fake_cmux
        surf = lr.CmuxSurface()
        eq("the workspace resolves to its ACTIVE PANE's terminal (the real tree shape)",
           surf._terminal_for("ws_l9"), "term_l9")
        ok("…and a browser tab on the same pane is not mistaken for it",
           surf._terminal_for("ws_l9") != "br_l9")
        eq("an unknown workspace resolves to None — never a guessed terminal",
           surf._terminal_for("ws_nope"), None)
        ok("the pane is readable through the resolved terminal", surf.screen_tail("ws_l9") is not None)
        reads = [c for c in calls if c[:1] == ["read-screen"]]
        ok("`read-screen` is given --terminal, never --workspace (a usage error on this build)",
           bool(reads) and all("--terminal" in c for c in reads)
           and not any("--workspace" in c for c in reads), repr(reads[:2]))

        lr._cmux = lambda argv, timeout=45: ((0, "", "") if argv[:2] == ["tree", "--json"]
                                             else (0, "   \n", ""))
        ok("an EMPTY capture is UNREADABLE (None), not a blank pane",
           lr.CmuxSurface().screen_tail("ws_l9") is None)
        lr._cmux = lambda argv, timeout=45: ((2, "", "usage") if argv[:2] == ["tree", "--json"]
                                             else (0, "x", ""))
        ok("a tree read that FAILED is unreadable, not a missing terminal",
           lr.CmuxSurface().screen_tail("ws_l9") is None)
    finally:
        lr._cmux = real


def leg_round7() -> None:
    print("\n── ROUND 7 — a stale pane, a dated ask, and an unread tail ──")

    # (1) ⛔ THE STALE PANE (P0). The question lane is persistent at index 0, so its tail normally
    # still shows the PREVIOUS question's brief — and every brief carries the same mandate tokens by
    # construction. Before `question_qid`, the prior brief satisfied the pane check: `verified: true`
    # off a question that never landed, and the dedupe (which honours only a prior `verified: true`)
    # then reported `already-routed` on every later tick — permanently. The fake is the #1187 class:
    # rc 0 from the transport, nothing painted.
    def spaces():
        return [{"id": "own", "name": "lane-7", "index": 1},
                {"id": "ws_q", "name": triage_arms.QUESTION_LANE, "index": 3}]

    prior = triage_arms.question_brief("lane-7", "Shall I merge the old thing?")

    class NeverPaints(FakeSurface):
        def send(self, ws, text):
            self.last_sent[ws] = text
            return True

    qid = triage_arms.question_qid("lane-7", "Shall I merge the new thing?")
    ok("the id is stable for one question",
       qid == triage_arms.question_qid("lane-7", "Shall I merge the new thing?"))
    ok("…and differs for another question",
       qid != triage_arms.question_qid("lane-7", "Shall I land the other thing?"))
    stale = NeverPaints(spaces=spaces(), screens={"ws_q": prior})
    p = triage_arms.arm_user_question("own", "lane-7", "Shall I merge the new thing?", stale,
                                      nap=lambda _s: None)
    ok("a PRIOR question's brief does not certify this one", p.verified is False, p.detail)
    ok("…and the missing token names THIS question's id",
       qid in (p.artifact.get("pane_missing") or []), str(p.artifact.get("pane_missing")))
    ok("…so nothing is asserted as delivered", p.as_dict()["verified"] is False)
    # Positive control: the SAME call, with a pane that does paint, must verify — otherwise the new
    # requirement is a blanket refusal rather than a proof.
    fresh = FakeSurface(spaces=spaces(), screens={"ws_q": ""})
    p2 = triage_arms.arm_user_question("own", "lane-7", "Shall I merge the new thing?", fresh,
                                       nap=lambda _s: None)
    ok("…while the SAME call verifies once the pane paints", p2.verified is True, p2.detail)

    # ⛔ AND A TRUNCATED PAINT IS NOT AN ACK EITHER (round 8, #4046 P0). Co-presence was enough for the
    # round-7 check: the current qid appears at char ~89, so a paint cut anywhere after it "had" the id
    # while the tail's mandate tokens belonged to the PREVIOUS brief. The three rows below are that
    # class: cut-118 and cut-400 must fail; a wrap landing inside the id must still verify (the id is
    # matched with optional whitespace, because the payload is sent flattened and the pane wraps it).
    cur_qid = triage_arms.question_qid("lane-7", "Shall I merge the new thing?")

    class Paints(FakeSurface):
        def __init__(self, cut=None, wrap=False, *a, **kw):
            super().__init__(*a, **kw)
            self.cut, self.wrap = cut, wrap
            self.spaces = [{"id": "own", "name": "lane-7", "index": 1},
                           {"id": "ws_q", "name": triage_arms.QUESTION_LANE, "index": 3}]
            self.screens = {"ws_q": prior}

        def move_workspace(self, ws, index):
            for sp in self.spaces:
                if sp["id"] == ws:
                    sp["index"] = index
            return True

        def send(self, ws, text):
            self.last_sent[ws] = text
            body = text if self.cut is None else text[:self.cut]
            if self.wrap:
                i = body.find(cur_qid)
                if i >= 0:
                    body = body[:i + 5] + "\n" + body[i + 5:]
            self.screens[ws] = self.screens.get(ws, "") + "\n" + body
            return True

    # ⛔ AND NOT AFTER THE MANDATE EITHER (round 9, #4046 P0): the six mandate tokens precede the
    # question body, so the smallest prefix that passed was 1061 of 1409 chars — the question and the
    # ask-owner step were gone while the record said "the full mandate visible on the pane", and the
    # dedupe then made the loss permanent. `end=` is the payload's last bytes.
    for cut, want_verified, label in ((118, False, "truncated at 118"),
                                      (400, False, "truncated at 400"),
                                      (1067, False, "truncated after the mandate (1067)"),
                                      (1200, False, "truncated at 1200"),
                                      (len(triage_arms.question_brief(
                                          "lane-7", "Shall I merge the new thing?")) - 20,
                                       False, "truncated 20 chars short"),
                                      (None, True, "a full paint")):
        pc = triage_arms.arm_user_question("own", "lane-7", "Shall I merge the new thing?",
                                           Paints(cut=cut), nap=lambda _s: None)
        ok("a %s is not a routed question" % label if not want_verified
           else "…and a %s verifies" % label,
           pc.verified is want_verified, "%s %s" % (pc.verified, pc.artifact.get("pane_missing")))
        if not want_verified:
            ok("…and the gap is NAMED, not merely failed (%s)" % label,
               bool(pc.artifact.get("pane_missing")),
               str(pc.artifact.get("pane_missing")))
    pw = triage_arms.arm_user_question("own", "lane-7", "Shall I merge the new thing?",
                                       Paints(wrap=True), nap=lambda _s: None)
    ok("…and a wrap landing INSIDE the id still verifies", pw.verified is True,
       str(pw.artifact.get("pane_missing")))

    # (2) ⛔ A LIVE ASK WEARING A DATE (P0). `_PAST_HARD` disarmed any clause carrying a temporal
    # anchor, so the ask's own OBJECT silenced it: seven real approval asks read `not-asked` and
    # routed `send-continue` into a lane waiting on its owner.
    # ⛔ AND (round 8, #4046 P0) THE OBJECT CARRIES THE COMPLETION VERB TOO. The round-7 gate asked
    # only "is there a completion in this clause", so "…the invoice I SENT last week" and "…the plan
    # we DECIDED yesterday" gated themselves off — 7 of 7 fresh inputs. The completion must start
    # before the addressed cue to be the LANE's.
    # ⛔ AND A CUE THE FALLBACK LIST DOES NOT KNOW (round 9, #4046 P0). The position rule was keyed on
    # a private 25-phrase regex while the module has 59 hand-off phrases, so asks phrased with the
    # other 34 had no offset and the completion gate did not apply — 14 of 14 read `not-asked`. The
    # offset now comes from the phrase that admitted the clause.
    for txt in ("Awaiting approval on the hotfix we released yesterday.",
                "Awaiting instruction on the numbers you verified yesterday.",
                "Over to you on the rollback we applied yesterday.",
                "Your read on the numbers we verified last week.",
                "Tell me if the deploy that went green yesterday is the one you want.",
                "Ping me when the report you verified last week is applied.",
                "Two of three tasks are done.\n\nAwaiting instruction on the deploy we applied "
                "yesterday.",
                "Awaiting your sign off on the invoice I sent last week.",
                "Awaiting your approval on the report I signed yesterday.",
                "Blocked on your approval of the contract we finished last week.",
                "Your confirmation on the plan we decided yesterday.",
                "Pending your approval of the fixed invoice from last week.",
                "Awaiting your decision on the design we closed yesterday.",
                "Awaiting your sign off on the fix approved by legal.",
                "Please approve yesterday's expense report.",
                "Please sign off on the invoice from last week.",
                "Please confirm the plan from Monday.",
                "I need your approval for the migration we discussed this morning.",
                "Awaiting your approval on the vendor quote from last month.",
                "Please confirm we ship at 14:02.",
                "Your call on the schema we reviewed last week.",
                "I'll merge after your approval."):
        e = ev(lane="lane-7", last_text=txt, lane_verdict="WIP-IDLE", steerable=True)
        may, r = triage.may_continue(e)
        ok("a dated ask is still an ask: %r" % txt[:38],
           triage.asks_owner(txt) == triage.ASKED and may is False, "%s %s" % (may, r.action))
    # …and the reports the anchor exists for are STILL reports (the split must not over-fire).
    # ⛔ THE MIRROR FAILURE WAS A REGRESSION OF THIS FIX (round 8, #4046 P1): a closed list of
    # completions let 9 of 10 plausible endings read `asked`, so a FINISHED lane lost its nudge and
    # was woken into the question lane. These inputs deliberately avoid the words the fix was written
    # from.
    for txt in ("Merged the PR on your approval at 14:02.",
                "Per your decision last week, the schema is closed.",
                "Approved by the rail yesterday.",
                "As you decided, shipped yesterday.",
                "Signed off by legal, so it went out.",
                "All 1436 tests passed at 14:02 after your approval.",
                "The suite went green at 14:02 after your approval.",
                "The deploy is live as of 14:02 after your approval.",
                "Checks came back clean at 14:02 after your approval.",
                "Everything is on prod after your approval at 14:02.",
                "The migration is applied; it went out at 14:02 after your approval.",
                "Nothing was blocked on your approval yesterday.",
                "Verified at 14:02 after your approval.",
                "The release went out at 14:02 after your approval.",
                # ⛔ AND THE MIRROR (round 9, #4046 P1): applying the position rule to DENIALS and to
                # possessive cues let 11 of 11 finished reports read `asked`. A denial denies the cue
                # wherever it sits; a possessive noun is a subject, not an addressed verb.
                "Your sign off came in and nothing needs your input.",
                "Your approval came through and nothing needs your input now.",
                "Your decision stands and nothing needs your input.",
                "Your approval is recorded and nothing needs your input on the schema.",
                "Your go-ahead landed and nothing needs your input now.",
                "Your call matched the plan already approved.",
                "Your call on the schema came out as you decided.",
                "Your decision aligned with the spec approved by legal."):
        e = ev(lane="lane-7", last_text=txt, lane_verdict="WIP-IDLE", steerable=True)
        may, r = triage.may_continue(e)
        ok("a completed report is not an ask: %r" % txt[:38], may is True,
           "%s %s" % (may, r.action))

    # (3) ⛔ AN UNREAD TAIL MAY NOT REACH THE DESTRUCTIVE ACTION (P2). `send-continue` was already
    # refused on UNREAD; `rerun` — the more destructive of the two — was not, so an unreadable tail on
    # a positively OPEN turn relaunched the lane.
    r = triage.route(ev(lane="lane-7", last_text="", turn=TURN_OPEN, lane_verdict="WEDGED",
                        steerable=True))
    ok("an unreadable tail does not relaunch a lane", r.action == "inspect", r.action)
    ok("…and the evidence names which ask state it was", "ask=unread" in r.evidence, r.evidence)

    # (4) ⛔ `execute()` WITH NO RELAUNCHER IS A PROOF GAP, NOT A CRASH (P2).
    rt = triage.Route(route="wedged", subcase="open-turn-never-closes", action="rerun",
                      proof=triage.PROOFS["rerun"], reason="fixture")
    raised = None
    pr = None
    try:
        pr = triage_arms.execute(rt, ev(lane="lane-7"), FakeSurface(spaces=spaces()), ws="ws_q")
    except TypeError as exc:                     # the failure mode under test
        raised = exc
    ok("a rerun with no relauncher does not raise", raised is None, str(raised))
    ok("…and it reports the tool's absence",
       pr is not None and pr.verified is False and "UNAVAILABLE" in pr.detail,
       pr.detail if pr else "")


LEGS = (
    ("precedence", leg_precedence),
    ("no-continue", leg_no_continue_to_question),
    ("arms-prove", leg_arms_prove),
    ("wedged-subcases", leg_wedged_subcases),
    ("unsteerable", leg_unsteerable),
    ("one-classifier", leg_one_classifier),
    ("ask-detector", leg_ask_detector),
    ("rows", leg_rows),
    ("e2e-question", leg_user_question_end_to_end),
    ("arm-continue", leg_arm_continue_proves_resumption),
    ("arm-wedged", leg_arm_wedged_remedies),
    ("records", leg_records),
    ("wiring", leg_wiring),
    ("cli-apply", leg_cli_apply),
    ("surface", leg_surface_terminal),
    ("round7", leg_round7),
)


def main(argv) -> int:
    if "--red-control" in argv:
        return 0 if run_red_control() else 1
    print("── lane triage router (#4046) — hermetic suite ──")
    print("   RED controls run by default at the end.\n")
    for _name, fn in LEGS:
        fn()
    print("")
    run_red_control()
    print("\nPASS=%d FAIL=%d" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
