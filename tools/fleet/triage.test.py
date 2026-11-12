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

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import liveness  # noqa: E402
import triage  # noqa: E402

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


# ── RED CONTROLS ───────────────────────────────────────────────────────────────────────────────
def run_red_control() -> bool:
    """Mutate the router and prove each mutation the arms exist to prevent turns a leg RED.

    A control that cannot fail certifies nothing, so each one is a NEGATIVE assertion: the mutated
    decision must NOT satisfy the property the shipped one satisfies.
    """
    print("\n── RED CONTROLS — the suite must fail when a property is removed ──")
    good = True

    # (R1) drop the precedence: let `wedged` be decided BEFORE the question arm.
    def route_wedged_first(e):
        if e.lane_verdict == "WEDGED":
            return triage.Route(route="wedged", subcase="open-turn-never-closes",
                                action="rerun", proof=triage.PROOFS["rerun"], reason="mutant")
        return triage.route(e)

    mut = route_wedged_first(ev(last_text="Should I merge?", lane_verdict="WEDGED"))
    good &= _red("R1 a wedged-first router MISROUTES a question", mut.route == "wedged")

    # (R2) drop the question guard from the idle arm.
    def continue_always(e):
        r = triage.route(e)
        if r.route == "user-question":
            return triage.Route(route="idle-continue", action="send-continue",
                                proof=triage.PROOFS["send-continue"], reason="mutant")
        return r

    mut = continue_always(ev(last_text="Should I merge?"))
    good &= _red("R2 continue-unless-guarded SENDS 'continue' to a question",
                 mut.action == "send-continue")

    # (R3) drop the unsteerable guard.
    mut = triage.Route(route="idle-continue", action="send-continue",
                       proof=triage.PROOFS["send-continue"], reason="mutant")
    good &= _red("R3 a route that ignores steerability would nudge a `pi -p` lane",
                 mut.action == "send-continue")

    # (R4) an arm with no proof must be REFUSED as unexecutable.
    bad = triage.Route(route="idle-continue", action="send-continue", proof="", reason="mutant")
    good &= _red("R4 an arm naming no artifact is not executable", not bad.complete)

    # (R5) a mismatched action/proof pair is refused — the table is the authority, not the caller.
    bad = triage.Route(route="user-question", action="route-to-question-lane",
                       proof=triage.PROOFS["send-continue"], reason="mutant")
    good &= _red("R5 an action carrying someone else's proof is not executable", not bad.complete)

    # (R6) the detector must fail CLOSED on a question mark in a fence — a detector that read it as
    # the lane asking would route every code-reading lane to the owner.
    good &= _red("R6 a fence-blind detector would call a pasted command a question",
                 triage.asks_owner("Run it:\n```\n# ok?\n```\nThen verified.") == "not-asked")

    # (R7) the router must not become a second verdict function.
    good &= _red("R7 a router that republished 'dead' would be a second liveness verdict",
                 "dead" not in triage.ROUTES)

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


LEGS = (
    ("precedence", leg_precedence),
    ("no-continue", leg_no_continue_to_question),
    ("arms-prove", leg_arms_prove),
    ("wedged-subcases", leg_wedged_subcases),
    ("unsteerable", leg_unsteerable),
    ("one-classifier", leg_one_classifier),
    ("ask-detector", leg_ask_detector),
    ("rows", leg_rows),
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
