#!/usr/bin/env python3
"""tools/fleet/triage.py — route a waiting lane to the RIGHT remedy (#4046).

WHY THIS EXISTS
---------------
The fleet already DETECTS well and routes badly. Three verdict vocabularies exist and none of them
answers the question a dispatcher actually has — *what do I DO with this lane?*:

    tools/fleet/liveness.py   dead · running-quiet · wedged · idle · unknown
    scripts/lane-status.py    WORKING · WAITING-CHILD · WIP-IDLE · DONE-IDLE · WEDGED ·
                              CHILD-STUCK · CHILD-OVERDUE · LONG-TOOL · UNATTRIBUTED-WORKING · …
    scripts/lane-actions.py   wait · rail · rerun · fix · review · ask-user

So one verdict — "looks idle" — became the answer to THREE different situations, and one of them is
actively harmed by that answer. Measured in this repo:

  * `scripts/turn-classify.py` already decides `asked_the_owner` (its `OUTCOMES`) — and then, for a
    lane that asked through the protocol, sets `kind = None`: NO ACTION. The question is recognised
    and nothing owns answering it. Its sibling `scripts/turn-end.py` guards with
    `lanes_with_open_question()`, which reads the **`owner-decision` label** — so a lane that asked in
    its pane and never posted the labelled comment is invisible to that guard, reads `WIP-IDLE`, and
    receives "CONTINUE IT" (`turn-end.py:build_wip_nudge`).
  * `scripts/orchestrator-heartbeat.sh` publishes `TRIAGE_HUMAN` as the beat clause
    `ASK-USER->raise a user question:` — an instruction in a message, not a route with an owner.
  * `scripts/cadence-nudge.sh:768` carries the same clause, and its own next clause is
    `WIP->say CONTINUE`, i.e. a question and a nudge are peers in one line.

WHAT THIS MODULE IS, AND WHAT IT IS NOT
---------------------------------------
It is a ROUTER, not a sixth classifier and not a second liveness verdict. It publishes no state from
`liveness.STATES`; it CONSUMES `liveness.Turn` (the #1254 open-turn contract) and `lane-status.py`'s
verdict as its evidence, and its output is a named ROUTE with the remedy and the PROOF that remedy owes.
`docs/ops/fleet-liveness.md` §0 keeps one verdict function; `STATES_DISJOINT` below and its pinned test
are what stop this file from quietly becoming a second one.

PRECEDENCE IS THE SAFETY PROPERTY: user-question > wedged > idle-continue
-----------------------------------------------------------------------
Never the reverse, because the two wrong orders each produce a specific, measured harm:

  * a question reported as `idle` gets the answer a lane that merely stopped needs — "continue",
    which tells the lane to proceed on a premise the owner has not decided. It is the one message
    this module exists to prevent.
  * a question reported as `wedged` gets the answer a stalled lane needs — check the process, then a
    kill. The correct remedy is "answer it", so the kill destroys the question.

Every "still working" signal is a VETO against `wedged`, never a reason to escalate — the direction
`docs/ops/pi-idle-repl-reaper-policy.md` records as *"no proof ⇒ not idle ⇒ never kill"*.

THE TWO RULES THE ARMS ARE BUILT ON
-----------------------------------
  ⛔ NEVER send "continue" to a lane whose last turn asks a question. `idle-continue` is unreachable
     while `asks_owner()` says `asked`, and unreachable while the question read is `unread` — an
     unread question is not a clean one, and the direction that can hurt is the one that assumes it is.
  ⛔ A `SENT` marker is a CLAIM, not an effect. Every route therefore carries the artifact its arm
     MUST verify (`Route.proof`), and `PROOFS` maps each to what counts at that artifact. A route with
     no proof named is not executable — see `Route.complete`.
"""

from __future__ import annotations

import os
import re
import sys

from dataclasses import dataclass, field
from typing import Optional, Sequence

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import liveness  # noqa: E402  — THE one liveness verdict function (#1178); consumed, never re-derived

# The routes this module publishes. Ordered by PRECEDENCE — the tuple order IS the tie-break, and
# `route()` returns the first it can endorse.
ROUTES = ("user-question", "wedged", "idle-continue", "none")

# ⛔ NO ROUTE MAY REUSE A LIVENESS STATE NAME (#1178). A reader that greps for `wedged` must not find
# a route and a state that mean different things — that is how `scripts/turn-classify.py` came to
# treat a lane as messageable off a verdict nobody had classified for it. `wedged` HERE names the
# ROUTE (the remedy family); `liveness.STATES`' `wedged` names the STATE. The intersection is pinned
# to exactly {"wedged"} BY A TEST, deliberately: making it empty would require inventing a second
# word for the state the fleet already decided on, and a second word is the worse defect.
STATES_DISJOINT = frozenset(ROUTES) & frozenset(liveness.STATES)
ALLOWED_STATE_OVERLAP = frozenset({"wedged"})

# ── the wedged subcases, each with its OWN remedy ────────────────────────────────────────────────
# `continue` appears in NONE of them. That is not a style choice: a wedged lane is one that has
# stopped making progress, and telling it to keep going is the instruction it has already not
# obeyed. Ordered as the ladder decides them — the child and boot shapes are POSITIVE evidence and
# are read before the generic open-turn shape, which is what `WEDGED` alone asserts.
WEDGED_SUBCASES = (
    "child-stuck",             # a persisted `task`/`subagent` child went quiet  (lane-status CHILD-STUCK)
    "child-overdue",           # a pending child past the harness's own silence bound (CHILD-OVERDUE)
    "boot-prompt",             # pi is sitting on its own "Press any key" boot-block prompt
    "model-retry",             # the lane is retrying the model, not making progress
    "tool-in-flight",          # a tool call whose DECLARED budget has not elapsed — wait, do not touch
    "open-turn-never-closes",  # an open turn that never closes: the generic wedge
    "wedged-unverified",       # something said WEDGED and the turn does not support it: inspect
)

# Remedy per subcase. Each value is an ACTION NAME the executor implements; none is "say continue".
REMEDIES = {
    "child-stuck": "repair-child",            # kill/re-dispatch the child, never the parent lane
    "child-overdue": "repair-child",          # the harness's silence bound already fired; same remedy
    "boot-prompt": "repair-boot-prompt",      # reuse cmux_dispatch.py's dismiss-and-resend
    "model-retry": "rerun",                   # the turn is retrying; a re-dispatch, not a nudge
    "tool-in-flight": "wait",                 # the tool declared its own timeout: it is not late yet
    "open-turn-never-closes": "rerun",        # stall-fix.sh's path
    "wedged-unverified": "inspect",           # the evidence contradicts the verdict: look, do not act
}

# The artifact each action must VERIFY before it may be reported as having worked. A `SENT` marker is
# a claim; this table is what makes the arms prove the effect instead:
#   * `transcript-growth` — the lane's own session file grew, or its turn count advanced, inside the
#     resumption bound. "accepted" is not "advanced" (see the evidence ladder: accepted · persisted ·
#     claimed · ADVANCED · completed · delivered).
#   * `question-lane-ack` — the question lane was resolved/created, the WORKSPACE LISTING puts it at
#     index 0, and the PANE the owner will read carries the research mandate + the USER QUESTIONS
#     PROTOCOL four parts. Both readings are re-taken after the action; the move's return code and
#     the text this module typed are NOT the artifact. A question forwarded raw has not been routed.
#   * `child-handoff-record` — a hand-off record was WRITTEN and RE-READ, carrying the child's own
#     `call_id`. The child's own record does not change (nothing is killed or restarted here), so a
#     proof that promised a change certified a presence test as an effect.
#   * `pane-ready` — the boot prompt is gone and the composer accepts a line.
#   * `commit-or-turn` — a new commit or a new turn exists; a re-dispatch that produced neither did not
#     happen.
#   * `written-reading` — nothing is executed; the artifact is the reading itself (wait/inspect), and
#     the arm must state WHY it is not acting.
PROOFS = {
    "send-continue": "transcript-growth",
    "route-to-question-lane": "question-lane-ack",
    # ⛔ NOT "the child's record CHANGED" (round 4, #4046 P0): the arm writes a hand-off and re-reads
    # it; nothing about the child changes, and claiming otherwise certified a presence test as an
    # effect for a whole review round.
    "repair-child": "child-handoff-record",
    "repair-boot-prompt": "pane-ready",
    "rerun": "commit-or-turn",
    "wait": "written-reading",
    "inspect": "written-reading",
    "refuse": "written-reading",
    "none": "written-reading",
}

# ── question detection ───────────────────────────────────────────────────────────────────────────
# ⛔ MECHANICAL, AND DELIBERATELY CONSERVATIVE IN ONE DIRECTION ONLY. `scripts/turn-classify.py` asks
# a Jev `choice` question (`TURN_QUESTION` / `OUTCOMES = asked_the_owner | stopped_with_work_left |
# finished_the_work`) and that answer, when a caller HAS it, outranks this one (`Evidence.ask_signal`).
# This predicate exists because the cruder fallback path (`scripts/turn-end.py`) has no classifier at
# all and needs an answer that costs nothing and cannot lie.
#
# It judges the ENDING, never the topic — the same rule turn-classify.py's own criteria state
# ("A turn that reports finished work and then adds 'tell me if you want more' still ENDED by
# asking"). It reads the WHOLE readable tail, because a hand-off followed by a status paragraph is
# the ordinary shape of a lane waiting on its owner (round 4, #4046 P0 — the paragraph window was
# removed for `?` in round 2 and for the phrase classes in round 4).
# ⛔ THE PHRASE LIST IS NOT THE ONLY DETECTOR, BUT IT STILL HAS TO COVER THE CLASS (round 5, #4046
# P1). A hand-written hand-off corpus at the previous head returned `not-asked` for 21 of 25 shapes —
# "I'm holding the deploy until you say otherwise.", "Ping me when you've picked one.", "Your move.",
# "Tell me to proceed and I will.", "This needs your input before I go further." — and every
# unambiguous one of those routed `idle-continue`/`send-continue`, i.e. straight to the harm. The
# vocabulary below is what those shapes have in common: a pause/hold/await verb, a request to be
# told, or a named dependency on the owner. `_HANDOFF_SHAPE` catches the open-ended ones by SHAPE
# (a sentence that BEGINS with one of these), because a closed list of whole sentences cannot.
_HANDOFF_SHAPE = re.compile(
    r"(?m)^\s*(?:awaiting|waiting on|waiting for your|pending your|tell me|ping me|reply|your move|"
    r"your input|i'?ll (?:wait|hold|pause)|i am (?:holding|waiting)|i'?m (?:holding|waiting|pausing)|"
    r"this needs your|needs your|blocked on your|holding (?:the|this|it)|over to you|"
    r"(?:i )?will wait)\b")

# ⛔ NON-ENGLISH, DELIBERATELY MINIMAL (round 5, #4046 P1). The fleet's lanes write in Spanish when the
# owner does; a detector that only reads English answers `not-asked` to "Quedo a la espera de tu
# aprobación". These are the same hand-off shapes, not a translation layer.
_HANDOFF_I18N = ("quedo a la espera", "esperando tu", "espero tu", "avísame", "avisame", "dime si",
                 "dime cuándo", "a tu criterio", "en tus manos", "requiere tu")

# ⛔ TWO KINDS OF DISARM, BECAUSE ONE IS SAFE AND ONE IS NOT (round 5, #4046 P1).
#   * `_PAST_HARD` — a TEMPORAL ANCHOR or a DENIAL. "yesterday", "from Monday", "at 14:02",
#     "after your approval", "Nothing needs your input now." A sentence carrying one of these reports
#     something already decided, whatever its tense markers say, so it is never an ask.
#   * `_PAST_SOFT` — a completion verb or possessive about a PAST decision ("matched your", "recorded
#     your", "was your call"). This disarms ONLY when the sentence carries no future/desiderative
#     marker, because the SAME words are a live hand-off in the future tense: "I'll merge on your
#     approval." is an ask, "Merged the PR on your approval at 14:02." is a report. Measured before
#     this split: adding `on your approval` to a single cue list read the FIRST as `not-asked` and
#     routed a waiting lane to `send-continue` — the harm, introduced by the fix for its mirror.
# ⛔ A TEMPORAL ANCHOR IS NOT A DISARM ON ITS OWN (fresh-context review round 7, #4046 P0).
# The anchor is scoped to the CLAUSE, but the decision an ask refers to is not: "Please approve
# yesterday's expense report." carries `yesterday`, and an unconditional `_PAST_HARD` read it as a
# report — measured, SEVEN live approval asks ("Please sign off on the invoice from last week.",
# "Please confirm the plan from Monday.", "Awaiting your approval on the vendor quote from last
# month.", "Please confirm we ship at 14:02.", …) all returned `not-asked` and routed
# `idle-continue`/`send-continue` into a lane waiting on its owner. The fix for the report's mirror
# had created the ask false-negative, in the one direction this module says it must never fail.
# So the anchor disarms only when the same clause ALSO reports a COMPLETION, and carries no future
# cue: "Merged the PR on your approval at 14:02." is still a report, "Please approve yesterday's
# expense report." is an ask. A DENIAL denies the cue itself, so it stays unconditional.
_PAST_HARD_DENIAL = re.compile(
    r"\b(?:nothing needs your|no need for your|doesn'?t need your|does not need your|"
    r"never needed your|nothing (?:is|was) blocked)\b")
# ⛔ A PAST-DECISION FRAME IS A REPORT ON ITS OWN (fresh-context review round 7, #4046 P2). "Per your
# decision last week" / "As you decided" / "already approved" / "approved by" name a decision
# already taken and cannot BE an ask. Kept separate from `_PAST_HARD_ANCHOR` because that list also
# holds "after your approval", which is a live ASK in the future tense ("I'll merge after your
# approval.") and so must stay completion-gated.
_PAST_HARD_FRAME = re.compile(
    r"\b(?:already approved|approved by|as you decided|per your decision|"
    r"your decision (?:was|stood))\b")
_PAST_HARD_ANCHOR = re.compile(
    r"\b(?:yesterday|last (?:night|week|month)|this morning|on monday|from monday|earlier today|"
    r"after your (?:approval|decision|call)|at \d{1,2}:\d{2}|previously)\b")
# ⛔ A CLOSED LIST OF COMPLETIONS LEAKS THE REPORT SIDE (round 8, #4046 P1). Nine of ten plausible
# completion endings — "All 1436 tests passed at 14:02 after your approval.", "The suite went green at
# 14:02 after your approval.", "Verified at 14:02 after your approval." — read `asked`, so a FINISHED
# lane lost its nudge and was woken into the question lane. The list now covers the past-tense
# completions the fleet actually writes. Both directions are pinned by controls built from inputs the
# list does NOT already contain, because the round-7 corpus was written from the same words as the fix.
_COMPLETION = re.compile(
    r"\b(?:merged|shipped|approved|decided|landed|closed|pushed|deployed|committed|completed|"
    r"finished|done|went through|went (?:green|out|live)|ran|wrote|sent|opened|removed|added|fixed|"
    r"recorded|signed|passed|applied|verified|came back|replied|responded|is live|on prod|"
    r"landed green|released)\b")
_PAST_SOFT = re.compile(
    r"\b(?:matched your|recorded your|went through|was your call|had approved|has approved|"
    # ⛔ NOT "on your approval" (round 6, #4046 P0). It is the ASK in "I'm blocked on your approval",
    # and the past-tense case it was added for ("Merged it on your approval at 14:02") is carried by
    # the HARD temporal anchor. In a soft list it silenced a live hand-off inside its own clause.
    r"thanks for your|for your approval step|was the right call)\b")
_FUTURE_CUE = re.compile(
    r"\b(?:i'?ll|i will|we'?ll|will|shall|should|would|waiting|await|until|once|before|please|"
    r"need|needs|let me|go-ahead|your call on)\b")
# ⛔ THE HOLD VERBS ARE **NOT** FUTURE CUES (round 8). The prototype that produced `_ADDRESSED` also
# proposed adding `awaiting|pending|blocked|holding` here, and measured against THIS corpus that
# over-fires two ordinary reports — "Landed it pending your approval from Monday." and "Holding the
# deploy was the right call." — because a hold verb is also how a lane describes a hold that ENDED.
# The position rule below fixes the same seven asks without touching the cue list.


# ⛔ THE CUE'S POSITION IN THE CLAUSE IS WHAT DECIDES WHOSE VERB THE COMPLETION IS (round 8, #4046
# P0). The round-7 gate asked only "is there a completion in this clause", and the ASK's own object
# supplies one: "Awaiting your sign off on the invoice I sent last week." / "Your confirmation on the
# plan we decided yesterday." / "Awaiting your sign off on the fix approved by legal." — all seven
# measured as `not-asked`, all routed `send-continue` into a lane waiting on its owner. A completion
# that starts AFTER the addressed cue belongs to the thing being asked about, not to the lane's work.
# ⛔ A HOLD CUE IS A VERB THE LANE ADDRESSES; A POSSESSIVE NOUN IS NOT (round 9, #4046 P1). Applying
# the position rule to a possessive over-fired on ordinary reports — "Your sign off came in and nothing
# needs your input.", "Your call matched the plan already approved." — 11 of 11 measured, each one a
# FINISHED lane losing its nudge and being queued as a question. "Awaiting your sign off on the fix
# approved by legal." is the shape the rule exists for; "Your decision aligned with the spec approved by
# legal." is a report.
# ⛔ ONE LIST OF DEFERRALS, USED BY EVERY BRANCH (round 11, #4046 P1). Round 10 added a second,
# hand-listed `_FRAME_FUTURE` next to this one and it fired on ordinary past-tense prose — "Already
# approved by legal BEFORE your approval window closed, so I merged it." read `asked`, suppressing a
# finished lane's nudge — while MISSING the deferral that matters most, `pending your word`, which this
# list already knew as a hold. The deferral forms below are the verb/preposition shapes ("wait for
# your", "hold the", "for your word"); bare possessives ("your approval") are deliberately absent —
# they are subjects in reports and were the cause of the round-9 over-fire.
_HOLD_CUE = re.compile(
    r"\b(?:awaiting your|awaiting a|awaiting approval|awaiting instruction|awaiting a steer|"
    r"waiting (?:on|for) your|wait(?:ing)? for your|pending your|blocked on your|"
    r"please (?:confirm|approve|sign)|sign off|hold here until|hold(?:ing)? (?:the|this|it)|"
    # ⛔ `need your` is here so a FUTURE dependency after a past-decision frame still defers — "Per your
    # decision I will need your approval before landing it." read `not-asked` without it (round 12,
    # #4046 P2). ⛔ `is/stays parked` was REMOVED: it made "Per your decision last week the release is
    # parked." — a plain report — read `asked`, and `pending your` already covers the deferral it was
    # added for.
    r"for your (?:word|steer|go-ahead|nod|call on)|need(?:s)? your)\b")
# An IMPERATIVE to the owner: everything after it is the thing being asked about.
# ⛔ THE VERB AFTER "PLEASE" IS THE SIGNAL, NOT "PLEASE" (round 12, #4046 P1). A bare `please`
# admitted nothing as an ask (so "Please review the vendor invoice." read `not-asked` ->
# `send-continue`) while it was strong enough to defeat a denial, which turned every report opening
# with an imperative of ATTENTION into an ask ("Please note the deploy finished at 14:02 and nothing
# needs your input now."). One list of request verbs is used by BOTH paths: it admits a clause, and a
# denial that follows one is the ask's object.
_IMPERATIVE = re.compile(
    r"\b(?:please (?:confirm|approve|sign|review|check|advise|tell|decide|choose|pick|look|"
    r"land|merge|ship|say|rule|steer|ok|okay)|tell me (?:if|whether|when)|"
    r"let me know (?:if|whether|when)|confirm (?:that|whether)|check (?:that|whether))\b")
# A state the clause REPORTS rather than one it ends on — used to keep a past-tense dependency
# ("…had been blocked on your approval since Tuesday") out of the ask's way.
# ⛔ IT TESTS THE PREDICATE'S OWN TENSE, NOT A BAG OF WORDS (round 12, #4046 P1). The first version
# matched `has been|since|yesterday|all morning|for a day` ANYWHERE between the completion and the
# dependency — but those mark when a block STARTED, i.e. evidence it is still running: "…the release
# HAS BEEN blocked on your approval since Tuesday." is a live block, and it read `not-asked` ->
# `send-continue` into a lane waiting on its owner. `was` also matched an unrelated subordinate clause
# ("I was told the merge is blocked"). Only the auxiliaries immediately before the predicate make it a
# report of a finished state.
_PAST_STATE = re.compile(r"\b(?:had|was|were)\s+(?:been\s+|all\s+)?$")
# A dependency PREDICATE — the owner is what the clause ends on.
_DEPENDENCY = re.compile(
    # ⛔ NOT `pending your` (round 10): it is the MODIFIER form — "Landed it pending your approval from
    # Monday." — and including it read that report as an ask. `blocked on` / `waiting on` / `awaiting`
    # are predicates the clause can END on; `pending` modifies what precedes it.
    r"\b(?:blocked on|blocked by|waiting on|waiting for|awaiting|only thing left|"
    r"all that'?s left|is the only blocker|need your (?:approval|decision|call|go-ahead|input))\b")
_ADDRESSED = re.compile(
    r"\b(?:awaiting your|awaiting a|waiting (?:on|for) your|pending your|blocked on your|"
    r"please (?:confirm|approve|sign)|sign off|your (?:approval|confirmation|decision|call|"
    r"go-ahead|input|word|sign[- ]?off))\b")


_CLAUSE_SPLIT = re.compile(r"[,;]|\s[—–]\s|\s-\s|\b(?:but|however|although|yet|whereas)\b",
                           re.IGNORECASE)


def _clauses(sent: str) -> list:
    """Split a sentence at CLAUSE boundaries, so a cue cannot disarm a different clause's ask.

    ⛔ (round 6, #4046 P0). Whole-SENTENCE disarming let a temporal anchor or a denial silence a LIVE
    ask in the same sentence — measured, four real hand-offs read `not-asked` and routed
    `send-continue` on a settled turn, and `rerun` on an open one:
      * "I'm blocked on your approval, unlike yesterday."        (anchor is in the OTHER clause)
      * "Nothing needs your input on the schema, but I do need your approval on the deploy."
      * "Awaiting your decision — I'll be at 14:02 standup and then free."
      * "The migration is written. I'll hold the deploy until you confirm; I'm back at 14:02."
    Each clause is judged on its own, so the cue has to belong to the phrase it disarms.
    """
    return [c for c in _CLAUSE_SPLIT.split(sent or "") if c and c.strip()]


def _disarmed(low: str, cue_at=None) -> bool:
    """Does THIS CLAUSE report something already decided? (see `_PAST_SOFT`/`_PAST_HARD_*`)

    `cue_at` is the offset of the hand-off phrase that ADMITTED this clause, as `asks_owner` matched
    it. ⛔ IT IS PASSED IN, NOT RE-DERIVED (round 9, #4046 P0). The position rule against a private
    `_ADDRESSED` list covered 25 of the module's own 59 hand-off phrases, so the other 34 — "awaiting
    approval", "awaiting instruction", "over to you", "up to you", "tell me if", "ping me", "your move",
    "your read on", "say the word", "in your hands", the Spanish entries — had no cue offset at all and
    the completion gate silently did not apply to them. Measured: 14 of 14 asks written that way read
    `not-asked` and routed `send-continue`. The caller already knows which phrase admitted the clause;
    asking a second list to guess it is how the two lists drift apart.
    """
    if cue_at is None:
        m = _ADDRESSED.search(low)
        cue_at = m.start() if m else None
    # ⛔ A DENIAL DENIES THE CUE — UNLESS IT IS THE ASK'S OBJECT (round 10, #4046 P0). Unconditional
    # was wrong in the other direction: "Please confirm nothing needs your attention on the staging
    # config before I promote." / "Please confirm nothing is blocked on the deploy." are imperative
    # asks whose OBJECT is a negative, and both read `not-asked` -> `send-continue` into a lane waiting
    # on its owner. A denial that starts AFTER an ADDRESSED HOLD is that object. Bare `sign off` is not
    # a hold for this purpose — it opens the ordinary report "Your sign off came in and nothing needs
    # your input." — which is why `_HOLD_CUE_DENIAL` is `_HOLD_CUE` minus it.
    denied = _PAST_HARD_DENIAL.search(low)
    if denied:
        # ⛔ A DENIAL IS UNCONDITIONAL — UNLESS AN IMPERATIVE PRECEDES IT (round 11, #4046 P1). Round
        # 10 carved the denial out on any preceding HOLD, which let past-tense reports through:
        # "Waiting on your approval held the release for a day and nothing needs your input now." read
        # `asked`, pausing a finished lane. The two asks the carve-out exists for are imperatives
        # ("Please confirm nothing needs your attention …"), so the imperative IS the discriminator.
        imp = _IMPERATIVE.search(low)
        if not (imp is not None and denied.start() > imp.start()):
            return True
    frame = _PAST_HARD_FRAME.search(low)
    if frame:
        # ⛔ A FRAME IS A REPORT UNLESS THE CLAUSE DEFERS TO THE OWNER (round 11, #4046 P1). "Per your
        # decision last week I'll wait for your go-ahead." defers AFTER naming the decision; "…, the
        # schema is closed." reports. One list decides both orders, so this cannot drift from the
        # vocabulary the way a hand-listed second regex did (and `pending your word` — a miss in round
        # 10 that routed `send-continue` into a lane waiting on its owner — is already in this list).
        if _HOLD_CUE.search(low) is None:
            return True
    if _PAST_HARD_ANCHOR.search(low):
        # An anchor needs a COMPLETION to be a report — one that is the LANE's, not the ask's object —
        # and a future cue vetoes even that.
        done = _COMPLETION.search(low)
        if not done:
            return False
        if cue_at is not None and done.start() > cue_at:
            return False
        # ⛔ AND THE CLAUSE MAY END ON A DEPENDENCY (round 10, #4046 P1): "Checks passed at 14:02 and
        # I'm blocked on your approval." is one clause (the splitter does not split on `and`), so the
        # lane's own completion sits BEFORE the hold and disarmed the ask. A dependency predicate that
        # starts after the completion is what the clause leaves the owner with.
        dep = _DEPENDENCY.search(low)
        if dep is not None and dep.start() > done.start():
            # ⛔ …A DEPENDENCY THE CLAUSE IS *REPORTING* IS NOT THE ONE IT ENDS ON (round 11, #4046
            # P1). "Deploy finished at 14:02 and the release had been blocked on your approval since
            # Tuesday." is a report of a block that is over; position alone read it as an ask and
            # suppressed the finished lane's nudge. A past-state marker between the completion and the
            # predicate is what separates "had been blocked" from "I'm blocked".
            if not _PAST_STATE.search(low[done.start():dep.start()]):
                return False
        return not _FUTURE_CUE.search(low)
    return bool(_PAST_SOFT.search(low)) and not _FUTURE_CUE.search(low)


def _sentences(body: str) -> list:
    """Split a readable tail into sentences/paragraphs, keeping line structure."""
    out = []
    for line in body.split("\n"):
        for part in re.split(r"(?<=[.!?])\s+", line):
            if part.strip():
                out.append(part)
    return out


_FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
# ⛔ TWO PHRASE CLASSES, NOT ONE (fresh-context review round 2, #4046 P1). The first cut matched
# `confirm` / `approve` as BARE SUBSTRINGS, so ordinary completion prose — "Confirmed: 210 pass, 0
# fail.", "Approved by the rail and green." — read as the lane ASKING THE OWNER. Measured: five of six
# realistic completion endings misclassified, each one routing a finished lane to the question lane
# and SUPPRESSING its nudge. A detector that fires on "Confirmed" is worse than no detector: it fills
# the owner's queue with lanes that have nothing to ask.
#   * `_ASK_FRAME`  — interrogative or a direct offer.
#   * `_HANDOFF`    — a declarative hand-off ("blocked on your decision"), the sentence a lane writes
#                    INSTEAD of a question mark. Both classes are read in EVERY sentence of the
#                    readable tail, and a sentence carrying a PAST-tense completion cue is not an ask
#                    (round 5, #4046 P1: "Merged the PR on your approval at 14:02" read as an ask).
# `confirm`/`approve` appear ONLY in their ADDRESSED forms ("please confirm", "needs your approval"),
# because the bare stem is a report of something already done.
_ASK_FRAME = (
    "shall i", "should i", "do you want", "want me to", "would you like",
    "your call", "which one", "which option", "which would you",
    "give me the go", "go ahead?", "proceed?", "ready?", "does that look right",
    "on to the next", "is that ok", "is that okay",
)
_HANDOFF = (
    "let me know", "say the word", "tell me if", "tell me whether", "blocked on your",
    "waiting on you", "waiting on your", "waiting for your", "waiting for approval",
    "awaiting your", "awaiting approval", "awaiting a decision", "over to you",
    "your decision", "up to you", "need your", "need approval", "needs approval",
    "needs your approval", "once you decide", "once you approve", "if you approve",
    "once you've approved", "on your approval", "for your approval", "pending your approval",
    "pending your decision", "please confirm", "please approve", "your confirmation",
    "your approval", "on your go",
    # ⛔ "sign off" (round 7, #4046 P0). "Please sign off on the invoice from last week." read
    # `not-asked`: the list had `for sign-off` / `for your sign-off` but not the ADDRESSED verb, so a
    # live approval ask routed `send-continue`. Spaced form only — "signed off by legal" is a report.
    "sign off",
    # ⛔ THE GO-AHEAD FAMILY (round 4, #4046 P0). Measured through the real consumer before this
    # line: "Migration written and tested. I'll wait for your go-ahead before applying it to prod."
    # returned `not-asked`, so `route_gate` said `may_nudge=True` and `turn-end.py` typed
    # "continue" into a lane waiting on the owner — the exact harm the module exists to prevent,
    # arriving through the phrase list rather than the `?` rule. The approval/authorisation asks are
    # the shape a merged-and-waiting lane actually writes.
    "go-ahead", "go ahead from you", "for your go", "waiting to hear", "ready for your",
    "hold here until", "until you confirm", "until you approve", "wait for your word",
    "your call on", "in your hands", "needs your sign", "for sign-off", "for your sign-off",
    # ⛔ THE SHAPES THE ROUND-5 CORPUS MEASURED AS MISSES (see `_HANDOFF_SHAPE` for the open-ended
    # ones). Each was `not-asked` and routed `send-continue` at 502fa170a.
    # ⛔ THE NEGATIVE DEPENDENCY (round 10, #4046 P1). "I can't proceed without sign-off." is the
    # shortest possible statement of a named dependency on the owner and it read `not-asked`, because
    # the list only carried the affirmative forms ("for sign-off", "needs your sign") and the
    # `_HANDOFF_SHAPE` list is line-anchored on hand-off WORDS, not on `I can't`. Cost, in the cheap
    # direction: "Merged it without your approval, as you'd said." now reads `asked`.
    "without sign-off", "without your sign", "without your approval", "without your go",
    "cannot proceed", "can't proceed", "cant proceed", "cannot move", "can't move",
    "say otherwise", "until you say", "for your input", "your input", "awaiting instruction",
    "awaiting a steer", "tell me to proceed", "reply and i", "ping me", "your move",
    "needs your input", "before i go further", "pause here", "holding the deploy", "holding this",
    "on your word", "your steer", "your read on", "wait for your input",
) + _HANDOFF_I18N + (
    # ⛔ THE CONSTRUCTION, NOT THE NOUNS (round 12, #4046 P1). Three rounds added one noun at a time
    # ("pending your word", "pending your go", "pending your sign") and each round a fresh reviewer
    # found the next noun: "pending your blessing", "waits for your OK". Enumerating a noun slot is a
    # hole with a name. These are the deferral CONSTRUCTIONS, so the noun is whatever the lane wrote.
    "pending your ", "awaiting your ", "waiting for your ", "wait for your ", "waits for your ",
    "blocked on your ", "need your ", "needs your ", "for your blessing", "for your ok",
    # ⛔ AND THE SPANISH SLICE IS THE SAME CONSTRUCTION (round 12, #4046 P1). The fleet's lanes write
    # Spanish when the owner does, and the I18N list above carries only whole phrases: 4 of 4 invented
    # Spanish declarative asks missed. A `?` would have caught them, which is exactly why the phrase
    # path must not depend on the owner's punctuation.
    "necesito tu ", "necesita tu ", "quedo pendiente", "pendiente de tu ", "a la espera de tu ",
    "espero tu ", "esperando tu ", "espera tu ", "requiere tu ", "requiero tu ",
)
ASKED = "asked"
NOT_ASKED = "not-asked"
UNREAD = "unread"


# A QUOTED line — a blockquote — is material the lane is REPORTING, not the lane speaking. Stripping
# it is what keeps `> Invalid config: which option did you mean?` out of the detector while still
# letting the surrounding prose be read (that fixture's own closing line is "Retried with the
# explicit path.").
_QUOTE_RE = re.compile(r"(?m)^\s*>.*$")
# ⛔ INLINE CODE IS REPORTED MATERIAL TOO (round 6, #4046 P2). The round-5 corpus measured
# `Ran \`grep -c '?' file\` and got 0.` and ``sh shall i merge?`` as an ASK, because only FENCED
# blocks and blockquotes were stripped. A backticked span is a command/output a lane is quoting, so it
# is removed with them — the same reasoning `_QUOTE_RE` carries.
_INLINE_CODE_RE = re.compile(r"`[^`\n]*`")


def readable_tail(text: str) -> str:
    """The assistant text with fenced code, inline code spans and QUOTED lines removed.

    A question mark inside a code block or a quoted tool error is not the lane asking the owner
    anything. Stripping `>` lines is what keeps `> Invalid config: which option did you mean?` out of
    the detector while the surrounding prose is still read.
    """
    return _QUOTE_RE.sub("", _INLINE_CODE_RE.sub(" ", _FENCE_RE.sub("\n\n", text or "")))


def last_paragraph(text: str) -> str:
    parts = [p.strip() for p in re.split(r"\n\s*\n", readable_tail(text)) if p.strip()]
    return parts[-1] if parts else ""


_WS = re.compile(r"\s")


def _has_ask_mark(body: str) -> bool:
    """Is there a `?` that is an ASK rather than part of a token? (round 4, #4046 P2)

    A `?` in a URL, a query string or a filename is not a question addressed to the reader, and
    treating it as one routes a FINISHED lane to the owner's question lane and suppresses its nudge —
    measured before this helper: `Deployed to https://ops.example.com/health?full=1 and it returned
    200.` and `Wrote the rule to docs/faq?/README.md and confirmed it lands.` both read `asked`.

    The rule is deliberately narrow: only a `?` that is INSIDE a token with a URL/path shape is
    discounted. Anything else — including the rhetorical question inside a report, which is a
    disclosed cost — still reads as an ask, because the opposite error sends "continue" to a lane
    waiting on the owner.
    """
    for m in re.finditer(r"\?", body):
        i = m.start()
        start = i
        while start > 0 and not _WS.match(body[start - 1]):
            start -= 1
        end = i + 1
        while end < len(body) and not _WS.match(body[end]):
            end += 1
        word = body[start:end]
        if "://" in word or word.endswith("/") or re.search(r"\?[A-Za-z_]+=", word):
            continue
        if re.search(r"[A-Za-z0-9]\?/", word):
            continue
        return True
    return False


def asks_owner(text: str) -> str:
    """Does this assistant message END by asking the OWNER something? `asked | not-asked | unread`.

    `unread` is a first-class answer, and the caller must treat it as "not proven clean" — the same
    discipline `liveness.py` applies to an unreadable turn boundary. An empty or unparseable read
    cannot be read as `not-asked`, because that reading is the one that licenses the harmful message.

    ⛔ A QUESTION MARK ANYWHERE IN THE READABLE TAIL IS THE SIGNAL (round 2, #4046 P1). Round 1 read
    only the last paragraph and then only the last two; both windows were falsified by the same shape —
    a question followed by one or two status paragraphs ("Should I merge?\n\nI checked the diff.\n\n
    Nothing else moved."), which read `not-asked` and produced `send-continue`. Widening a paragraph
    window only moves the boundary, so the window is gone: in an agent's own report, a `?` outside a
    fence or a quote is addressed to the reader. The two phrase classes then cover the ASK THAT IS
    WRITTEN WITHOUT ONE, in every sentence of the same tail.

    THE TRADE IS DELIBERATE AND ONE-DIRECTIONAL: a `?` quoted in prose (not blockquoted) can make a
    comment read as a question, which costs a question-lane wake-up and one pass of nudge suppression.
    The opposite error sends "continue" to a lane that is waiting on the owner, which is the harm this
    entire module exists to prevent. Fail towards the cheap error.
    """
    body = readable_tail(text)
    if not body.strip():
        return UNREAD
    if _has_ask_mark(body):
        return ASKED
    # ⛔ THE WHOLE BODY, FOR BOTH CLASSES (round 4, #4046 P0). Round 2 removed the paragraph WINDOW
    # for `?` and left it in place for the phrase classes, so half the detector still read only the
    # last paragraph — and measured through the real consumer, "Blocked on your decision.\n\n
    # Everything else is green." returned `not-asked` (may_nudge=True) while the SAME sentence as the
    # final paragraph returned `asked`. A hand-off followed by a status paragraph is the ordinary
    # shape of a lane that has finished everything except the thing it is waiting on, so the
    # asymmetry had no defensible side: both classes now read the whole readable tail.
    for sent in _sentences(body):
        for clause in _clauses(sent):
            low = " ".join(clause.lower().split())
            if not low:
                continue
            at = [low.find(phrase) for phrase in _ASK_FRAME + _HANDOFF]
            at = [i for i in at if i >= 0]
            # ⛔ A REQUEST TO THE OWNER ADMITS THE CLAUSE (round 12, #4046 P1): "Please review the vendor
            # invoice." has no `_HANDOFF` phrase and no `?`, so it was never even a candidate while
            # `please confirm …` (also an imperative) was. Same predicate as the denial carve-out.
            imp = _IMPERATIVE.search(low)
            if imp is not None:
                at.append(imp.start())
            shaped = _HANDOFF_SHAPE.match(clause.strip().lower())
            if not at and not shaped:
                continue
            cue_at = min(at) if at else 0
        # ⛔ A PAST-TENSE COMPLETION CUE DISARMS THE PHRASE (round 5, #4046 P1). Widening the phrase
        # classes to the whole tail (round 4) made ordinary completion prose read as an ask —
        # measured, 7 of 8 of "Merged the PR on your approval at 14:02, checks green.", "Everything
        # went through after your approval yesterday.", "That join was your call and it held up.",
        # "Recorded your decision in the doc; shipped it." Each routed a FINISHED lane to the owner's
        # question lane and suppressed its nudge — a regression of a fix this same change made in
        # round 2. The cue is per SENTENCE, so a tail whose FIRST sentence is a hand-off and
        # whose second reports a past merge still reads as an ask.
            if _disarmed(low, cue_at):
                continue
            return ASKED
    return NOT_ASKED


# ── a lane RETRYING the model is a wedge subcase with its own remedy ──────────────────────────
# ⛔ THIS NEEDED A PRODUCER (fresh-context review, #4046). The subcase was DECLARED and reached only
# by a hand-built fixture — `grep -rn model_retry` found nothing that set it — so it certified a
# reachability the acquirer could not produce. The signature is mechanical and narrow: the lane's own
# last words name a provider/transport retry, which is the thing a `continue` cannot fix and a
# re-dispatch can.
# ⛔ THE NUMERIC IS WORD-ANCHORED (round 3, #4046 P0). A bare `429` matched any issue/PR number that
# CONTAINS those digits — measured: `retry_signature("Merged PR #14290 and verified all checks.")` was
# True, so a WORKING lane routed `wedged/model-retry` whose remedy is `rerun` (a relaunch) and was
# re-dispatched for having mentioned a ticket. `\b429\b` still matches `HTTP 429`, `429 Too Many
# Requests`, and `got 429`, and cannot match inside `#14290` (no boundary between `1` and `4`).
_RETRY_RE = re.compile(
    r"(rate[ -]?limit|\b429\b|too many requests|overloaded|retrying|retry in |"
    r"temporarily unavailable|upstream (error|timeout)|provider (error|unavailable))", re.I)


def retry_signature(text: str) -> bool:
    """Does the lane's tail say it is RETRYING the model rather than progressing?

    Scoped to the LAST PARAGRAPH, not the whole message: a long report that mentions a rate-limit fix
    somewhere in the middle is a report about a bug the lane FIXED, not a lane that is retrying. The
    remedy for this verdict is `rerun` (a relaunch), so the signature may only read what the lane is
    saying as it stops.
    """
    return bool(_RETRY_RE.search(last_paragraph(text)))


def last_text_from_jsonl(path: Optional[str]) -> str:
    """The last assistant message's TEXT from a session JSONL, or "". Bounded, never whole-file.

    THE one implementation of "what did this lane last say", shared by the operator CLI and by
    `scripts/turn-end.py` — a second reader would be a second answer to a question the router's
    whole precedence depends on, and the two would eventually disagree about a question mark.
    """
    if not path:
        return ""
    try:
        entry, _last, _size = liveness._last_message_entry(path)
    except Exception:                                             # noqa: BLE001
        return ""
    if not isinstance(entry, dict):
        return ""
    msg = entry.get("message")
    if not isinstance(msg, dict) or msg.get("role") != "assistant":
        return ""
    content = msg.get("content")
    if isinstance(content, str):
        return content
    parts = []
    for c in content or []:
        if isinstance(c, dict) and c.get("type") == "text":
            parts.append(c.get("text") or "")
        elif isinstance(c, str):
            parts.append(c)
    return "\n".join(p for p in parts if p)


# ── evidence and route ──────────────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Evidence:
    """Everything the route decision may read. Each field has exactly ONE owner.

    ``turn``            — ``liveness.Turn`` from ``turn_from_jsonl`` (#1254). The ONLY source of
                          "positively open"; `None` means the boundary could not be read.
    ``last_text``       — the last assistant message's text, from the same tail read.
    ``ask_signal``      — ``asked``/``not-asked``/``unread``, a SEAM for a caller that has run the Jev
                          classifier (`scripts/turn-classify.py`'s `asked_the_owner`). ⚠️ No
                          production caller supplies it today (round 2 review, #4046): the mechanical
                          `asks_owner` is the operative detector, and this field is tested but not
                          wired. It may only ever PROMOTE, never demote.
    ``lane_verdict``    — a PUBLISHED ``lane-status.py`` verdict string, or ``""`` when unread. It is
                          the only source of CHILD-STUCK / CHILD-OVERDUE / LONG-TOOL / WEDGED.
    ``child_state``     — the child's own recorded state (``""``, ``stuck``, ``overdue``, ``healthy``).
    ``steerable``       — can this incarnation be sent input at all? ``None`` = unread. A lane
                          launched with ``pi -p`` cannot: one turn, no stdin, exits. Sending it
                          "continue" is a no-op that still writes a `SENT` marker.
    ``boot_prompt``     — pi is sitting on its boot-block prompt (the dispatcher's ``boot_blocked``).
    ``model_retry``     — the transcript shows the lane retrying the model rather than progressing.
    ``tool_in_flight``  — a tool call is in flight (``liveness.Tool`` in the tail).
    ``tool_budget_open``— that call DECLARED a timeout (``timeout 3000s``) which has not elapsed. A
                          long tool is not a wedge; its own budget is the bound.
    """

    lane: str = ""
    turn: Optional["liveness.Turn"] = None
    last_text: str = ""
    ask_signal: str = ""
    lane_verdict: str = ""
    child_state: str = ""
    steerable: Optional[bool] = None
    boot_prompt: Optional[bool] = None
    model_retry: Optional[bool] = None
    tool_in_flight: bool = False
    tool_budget_open: bool = False
    # ⛔ "UNREADABLE" AND "EXPIRED" ARE DIFFERENT EVIDENCE (round 2, #4046 P2). The first cut folded
    # both into `tool_budget_open=False`, so a tool past its DECLARED timeout was parked at `wait` with
    # a reason that MISSTATED the reading ("not late on evidence"). A late call is the opposite: the
    # budget is read and gone, which is a positive reason to look.
    tool_budget_read: bool = False


@dataclass(frozen=True)
class Route:
    """One decision: what this lane IS (route), which shape of it, what to do, and what to prove.

    ``complete`` is the executable-predicate: a route that names an arm but no artifact is refused,
    because an arm with no proof is exactly the `SENT`-marker-as-evidence class this module removes.
    """

    route: str
    action: str
    proof: str
    reason: str
    subcase: str = ""
    evidence: str = ""

    @property
    def complete(self) -> bool:
        return bool(self.route and self.action and self.proof
                    and PROOFS.get(self.action) == self.proof)

    def as_dict(self) -> dict:
        return {"lane": None, "route": self.route, "subcase": self.subcase,
                "action": self.action, "proof": self.proof, "reason": self.reason}


# Verdicts that are THEMSELVES proof the lane is working. Each is a veto against every `wedged`
# subcase whose remedy acts on the lane (a re-dispatch, a relaunch): the instrument saw it consume CPU,
# hold a child, or run a declared tool, so nothing downstream may be told it has stopped.
WORKING_VERDICTS = ("WORKING", "WAITING-CHILD", "LONG-TOOL", "UNATTRIBUTED-WORKING")


def _turn_open(ev: Evidence) -> bool:
    """POSITIVELY open — `liveness.Turn.stalled`, and never an abstention (#1254)."""
    return bool(ev.turn is not None and getattr(ev.turn, "stalled", False)
                and not getattr(ev.turn, "abstain", False))


def _turn_resting(ev: Evidence) -> bool:
    """A turn that ENDED. An abstention is not resting — it licenses no disposition."""
    t = ev.turn
    return bool(t is not None and not getattr(t, "stalled", False)
                and not getattr(t, "abstain", False))


def _question(ev: Evidence) -> str:
    mech = asks_owner(ev.last_text) if ev.last_text else UNREAD
    supplied = (ev.ask_signal or "").strip().lower()
    if supplied == ASKED or mech == ASKED:
        return ASKED          # never downgrade: the mechanical answer may not be talked out of it
    # ⛔ `UNREAD` BEATS A SUPPLIED `not-asked` TOO (fresh-context review, #4046). An empty tail is an
    # empty tail whoever asserts otherwise: `asks_owner`'s own docstring says an unreadable read
    # cannot be read as `not-asked`, and honouring a caller's `not-asked` over it let
    # `Evidence(last_text="", ask_signal="not-asked")` reach `send-continue` — the one message the
    # module exists to prevent. Latent when fixed (nothing set `ask_signal`), which is exactly how a
    # fail-open survives until the day a caller starts using the field.
    if mech == UNREAD:
        return UNREAD
    if supplied in (NOT_ASKED, UNREAD):
        return supplied
    return mech


def route(ev: Evidence) -> Route:
    """Decide the lane's ROUTE. Total, pure, and ordered by the precedence safety property.

    The order of the checks inside `_route_ladder` IS the contract. Do not reorder them to make a
    case read better: each inversion has a measured harm, named in the module docstring.

    ⛔ ONE POST-PASS, AND ONLY ONE (round 4, #4046 P1). The ladder decides from the VERDICT and the
    TURN; it does not, on its own, know that the turn's text asks the owner. So a question on an
    OPEN turn — `liveness.Turn(True, "turn-open:no-terminal-stop")`, the crash/hang-mid-write shape —
    fell through to `wedged/open-turn-never-closes` whose remedy is `rerun`, i.e. a RELAUNCH of a
    lane that is sitting on a question. Measured: 27 of 468 enumerated combinations reached a
    lane-destroying action from a lane that had asked. A relaunch destroys the question just as
    surely as a "continue" answers it wrongly, so the veto is applied to the DECIDED route rather
    than re-ordering the ladder: the wedge verdict may still be right (an open turn that never
    closes IS worth inspecting), but the action may not be the destructive one.
    """
    ask = _question(ev)
    r = _route_ladder(ev, ask)
    # ⛔ `UNREAD` BELONGS IN THE VETO TOO (fresh-context review round 7, #4046 P2). The tail could not
    # be read, so it is not a clean one — the same rule that already refuses `send-continue` on
    # `UNREAD` in the ladder (`:685`). Measured before this: an empty tail on a positively OPEN turn
    # with a `WEDGED` verdict reached `wedged/open-turn-never-closes` -> `rerun`, i.e. the MORE
    # destructive of the two actions was the one the unread state still licensed. It was not
    # destructive only because `lane-relaunch.py` re-checks the pane itself; a router may not rely on
    # a downstream tool for its own stated safety property.
    if ask in (ASKED, UNREAD) and r.action == "rerun":
        return Route(
            route="wedged", subcase=r.subcase, action="inspect", proof=PROOFS["inspect"],
            reason="the wedge reading and the tail disagree: the turn is still open AND its last "
                   "words ask the owner (ask=%s), so a relaunch would destroy the question before "
                   "it is answered — inspect the lane and route the question instead" % (ask,),
            evidence=(r.evidence or "") + " ask=" + ask,
        )
    return r


def _route_ladder(ev: Evidence, ask: str) -> Route:
    """The ordered ladder. Called only by `route()`, which owns the one post-pass above."""

    # ── 1. user-question — before everything, and never on a positively OPEN turn ────────────────
    # An open turn means pi is still working; the text at its tail is what it is saying mid-flight,
    # not a resting question. A question on a RESTING or ABSTAINED boundary is a question either way,
    # and the abstained case is exactly why this arm may not require `_turn_resting`: an unreadable
    # boundary with a question on it must still never receive "continue".
    if ask == ASKED and not _turn_open(ev):
        return Route(
            route="user-question", action="route-to-question-lane", proof=PROOFS["route-to-question-lane"],
            reason="the last turn ended by asking the owner",
            evidence="turn=%s" % (getattr(ev.turn, "reason", "unread"),),
        )

    # ── 2. wedged — named subcases, in the ladder's own order ──────────────────────────────────
    # A still-working signal VETOES every subcase below it: `wait` is not a wedge response, it is the
    # absence of one, and it must be reachable from every branch that could otherwise escalate.
    if ev.tool_in_flight and ev.tool_budget_open:
        return Route(route="wedged", subcase="tool-in-flight", action=REMEDIES["tool-in-flight"],
                     proof=PROOFS[REMEDIES["tool-in-flight"]],
                     reason="a tool is in flight inside its own DECLARED budget — it is not late yet",
                     evidence="lane-status verdict=%r budget=read-open" % (ev.lane_verdict,))

    if ev.tool_in_flight and ev.tool_budget_read and not ev.tool_budget_open:
        # The budget was READ and is GONE. That is not "not late on evidence" — it is late, and
        # pretending otherwise is how a lane that overran its own declared timeout sits parked.
        sc = "tool-in-flight"
        return Route(route="wedged", subcase=sc, action="inspect", proof=PROOFS["inspect"],
                     reason="the in-flight tool has OVERRUN its own declared budget — inspect before "
                            "acting, because a long tool is still not proof of a stall",
                     evidence="lane-status verdict=%r budget=read-expired" % (ev.lane_verdict,))

    if ev.lane_verdict == "CHILD-STUCK" or ev.child_state == "stuck":
        sc = "child-stuck"
        return Route(route="wedged", subcase=sc, action=REMEDIES[sc], proof=PROOFS[REMEDIES[sc]],
                     reason="a persisted child went quiet; the PARENT is not the thing to touch",
                     evidence="verdict=%r child=%r" % (ev.lane_verdict, ev.child_state))

    if ev.lane_verdict == "CHILD-OVERDUE" or ev.child_state == "overdue":
        sc = "child-overdue"
        return Route(route="wedged", subcase=sc, action=REMEDIES[sc], proof=PROOFS[REMEDIES[sc]],
                     reason="a pending child is past the harness's own silence bound",
                     evidence="verdict=%r child=%r" % (ev.lane_verdict, ev.child_state))

    if ev.boot_prompt:
        sc = "boot-prompt"
        return Route(route="wedged", subcase=sc, action=REMEDIES[sc], proof=PROOFS[REMEDIES[sc]],
                     reason="pi is sitting on its boot-block prompt; the send was EATEN, not ignored",
                     evidence="boot_prompt=True")

    # ⛔ A RETRY SIGNATURE IS NOT ON ITS OWN A WEDGE (round 3, #4046 P0). The remedy here is `rerun` —
    # a RELAUNCH — so the branch may only fire where the module's own rule holds: a POSITIVELY OPEN
    # turn (the retry is happening now, so the turn never closed) and no proven-working signal (every
    # "still working" signal is a veto, per the docstring). Measured without these two guards: a lane
    # reading `WORKING` that merely MENTIONED a 429 routed to `wedged/model-retry` → `rerun`, i.e. a
    # working lane re-dispatched and its work discarded. Veto beats evidence, and abstention is not
    # progress: an unreadable verdict is not a working signal, but an open turn still has to be there.
    if ev.model_retry and _turn_open(ev) and ev.lane_verdict not in WORKING_VERDICTS:
        sc = "model-retry"
        return Route(route="wedged", subcase=sc, action=REMEDIES[sc], proof=PROOFS[REMEDIES[sc]],
                     reason="an OPEN turn whose tail says it is retrying the model — not progressing",
                     evidence="model_retry=True verdict=%r" % (ev.lane_verdict,))

    if ev.tool_in_flight:
        # In flight with NO readable budget: nothing proves it late either. `wait` — the subcase exists
        # so that "I saw a tool" can never become "kill it".
        sc = "tool-in-flight"
        return Route(route="wedged", subcase=sc, action=REMEDIES[sc], proof=PROOFS[REMEDIES[sc]],
                     reason="a tool is in flight and its budget is not readable — not late on evidence",
                     evidence="tool_budget_read=False")

    if ev.lane_verdict == "WEDGED":
        if _turn_open(ev):
            sc = "open-turn-never-closes"
            return Route(route="wedged", subcase=sc, action=REMEDIES[sc], proof=PROOFS[REMEDIES[sc]],
                         reason="the transcript shows a POSITIVELY open turn that never closes",
                         evidence="turn=%s" % (getattr(ev.turn, "reason", "unread"),))
        # ⛔ THE VERDICT AND THE TURN DISAGREE. `liveness.py`'s contract is that wedged needs a
        # positively open turn (#1254); a WEDGED reading with a resting or unreadable turn is the
        # instrument being wrong about the lane, so the remedy is to LOOK. Never "continue" (the
        # lane may be resting on a question) and never a kill (there is no proof it stalled).
        sc = "wedged-unverified"
        return Route(route="wedged", subcase=sc, action=REMEDIES[sc], proof=PROOFS[REMEDIES[sc]],
                     reason="a WEDGED verdict with no positively open turn — the evidence contradicts "
                            "the verdict, so inspect rather than act",
                     evidence="verdict=WEDGED turn=%s" % (getattr(ev.turn, "reason", "unread"),))

    # ── 3. idle-continue — only where a continuation is both SAFE and POSSIBLE ──────────────────
    if ev.lane_verdict in ("DONE-IDLE", "WIP-IDLE", "EMPTY", "UNBOUND") and _turn_resting(ev):
        if ask == UNREAD:
            # Not a question we can see — and not a lane we can prove is NOT asking one. `refuse`, not
            # `none`: an arm WAS earned on the mechanical evidence and a guard withheld it, and a
            # withheld arm that reads as "nothing to do" is how a lane sits un-nudged and unheard.
            return Route(route="none", action="refuse", proof=PROOFS["refuse"],
                         reason="the turn's tail could not be read, so a question cannot be ruled out",
                         evidence="ask=unread")
        if ev.steerable is not True:
            # ⛔ A `pi -p` LANE CANNOT BE STEERED (one turn, no stdin, exits). A "continue" typed at
            # it is a no-op that still writes a SENT marker and makes the lane read BUSY for an hour
            # — a claim with no effect behind it, which is the exact defect this module removes.
            return Route(route="none", action="refuse", proof=PROOFS["refuse"],
                         reason=("this incarnation is not steerable (%s) — a continue would be a "
                                 "no-op that still claims a send"
                                 % ("unread" if ev.steerable is None else "pi -p")),
                         evidence="steerable=%r" % (ev.steerable,))
        return Route(route="idle-continue", action="send-continue", proof=PROOFS["send-continue"],
                     reason="a completed turn, no question, no child in flight — a continuation is due",
                     evidence="verdict=%r turn=%s" % (ev.lane_verdict,
                                                      getattr(ev.turn, "reason", "unread")))

    # ── 4. an IDLE VERDICT WE COULD NOT READ IS A REFUSAL, NOT "NOTHING TO DO" ──────────────────
    # ⛔ (round 5, #4046 P1). With an idle verdict and an UNREADABLE turn boundary — no session file,
    # or a boundary the reader could not parse — the ladder fell through to `none`/`none`, which is
    # the "nothing to do" reading the branch above explicitly forbids. Downstream, `lane-route.py`
    # counts only `action == "refuse"`, so a fleet-wide unreadable population disappeared from
    # `router=refuse:N` and read as a quiet fleet, and `turn-end.py` suppressed the nudge on EVERY
    # tick (it used to send it). `refuse` is the honest answer: an arm WAS earned on the verdict and
    # the read withheld it.
    if ev.lane_verdict in ("DONE-IDLE", "WIP-IDLE", "EMPTY", "UNBOUND") and not _turn_resting(ev):
        return Route(route="none", action="refuse", proof=PROOFS["refuse"],
                     reason="an idle verdict whose turn boundary could not be read (%s) — a nudge "
                            "cannot be ruled safe, and this refusal is COUNTED rather than read as "
                            "an idle lane" % (getattr(ev.turn, "reason", "unread"),),
                     evidence="verdict=%r ask=%s" % (ev.lane_verdict, ask))

    # ── 5. none — everything still working, or nothing readable ─────────────────────────────────
    why = {
        "WORKING": "the lane is working (CPU/output proven)",
        "WAITING-CHILD": "a child is in flight and healthy — the parent is correct to wait",
        "LONG-TOOL": "a declared tool budget is running",
        "UNATTRIBUTED-WORKING": "something in the lane's own directory is consuming CPU",
    }.get(ev.lane_verdict,
          "no route is earned: verdict=%r turn=%s ask=%s" %
          (ev.lane_verdict, getattr(ev.turn, "reason", "unread"), ask))
    return Route(route="none", action="none", proof=PROOFS["none"], reason=why,
                 evidence="verdict=%r" % (ev.lane_verdict,))


# ── acquisition: can this incarnation be steered at all? ──────────────────────────────────────
# ⛔ A `pi -p` LANE CANNOT BE STEERED — one turn, no stdin, exits — so a "continue" typed at it is a
# no-op that still writes a SENT marker, and the fleet reads that marker back as BUSY for an hour.
# This lives here (beside `route`, like `gather()` beside `evaluate()` in `liveness.py`) so the
# operator CLI and the nudge path measure it the SAME way instead of each guessing from a verdict.
#
# ⛔ `None` IS A FIRST-CLASS ANSWER AND MUST NOT BE READ AS "STEERABLE". The pid probe is the fleet's
# own identity CLI (`scripts/lib/pid-identity.sh argv-candidates`), and an unread probe is the one
# case where "just send it" would put a claim with no effect behind it into the marker dir.
_PRINT_MODE = ("-p", "--print")


def steerable(sid: Optional[str] = None, *, ws: Optional[str] = None,
              session_path: Optional[str] = None) -> Optional[bool]:
    """Can this incarnation be sent input at all? `True` / `False` / `None` (no evidence).

    ⛔ TWO AFFIRMATIVE PATHS, BECAUSE THE FIRST ONE ALONE STOPS THE WHOLE FLEET FROM BEING NUDGED
    (fresh-context review finding P0, measured). `argv_candidates` finds pids whose argv carries the
    session in a RESUME form (`--session <sid>` / `-r` / `--resume`, `scripts/lib/pid-identity.sh`).
    A live interactive `pi` on this fleet has argv exactly `pi` — measured on five of them — so the
    argv read returns EMPTY for every ordinary lane, this function answered `None`, the router refused
    `idle-continue`, and `scripts/turn-end.py` therefore nudged NOBODY. A refusal that fires on every
    lane is not the safe direction; it is the inert-enforcer class the change exists to remove.

    The second path is the honest affirmative the fleet already relies on: A LANE WHOSE SESSION
    TRANSCRIPT IS BOUND TO A CMUX WORKSPACE IS INTERACTIVE. It can be typed into and it takes a next
    turn. This is not a guess from a verdict — it is the construction of the population: an
    orchestrator lane runs `pi -p --no-session` (`lane.sh`), so it has NEITHER a session file NOR a
    bound workspace, and cannot satisfy this branch. `False` still requires POSITIVE proof of print
    mode (a readable argv carrying `-p` / `--print`), and `None` remains "no evidence" — the caller
    may refuse on it, and the router does.
    """
    if sid:
        try:
            pids, ok = liveness.argv_candidates(sid)
        except Exception:                                         # noqa: BLE001
            pids, ok = [], False
        if ok and pids:
            import subprocess
            for pid in pids:
                try:
                    p = subprocess.run(["ps", "-o", "args=", "-p", str(pid)],
                                       capture_output=True, text=True, timeout=15)
                except (OSError, subprocess.SubprocessError):
                    continue
                argv = (p.stdout or "").strip()
                if not argv:
                    continue
                return not any(tok in _PRINT_MODE for tok in argv.split())
    if ws and session_path:
        return True
    return None


def _tool_row(row):
    """The in-flight tool dict, if the row names one (the producer's own key)."""
    tok = row.get("tool")
    return tok if isinstance(tok, dict) else None


def _tool_in_flight(row) -> bool:
    return bool(row.get("tool_in_flight") or _tool_row(row))


def _tool_budget_read(row) -> bool:
    """Was the call's DECLARED budget actually read? True when a timeout is on the record."""
    if "tool_budget_read" in row:
        return bool(row.get("tool_budget_read"))
    tok = _tool_row(row)
    return bool(tok) and isinstance(tok.get("timeout"), (int, float))


def _tool_budget_open(row) -> bool:
    """Is the declared budget still open? Only a READ budget can be open; an unread one is not."""
    if "tool_budget_open" in row:
        return bool(row.get("tool_budget_open"))
    tok = _tool_row(row)
    if not tok:
        return False
    timeout, age = tok.get("timeout"), tok.get("age")
    if isinstance(timeout, (int, float)) and isinstance(age, (int, float)):
        return age < timeout
    return False


def route_rows(rows: Sequence[dict]) -> list:
    """Route a whole `lane-status.py --json` population, preserving its evidence into each result.

    Kept here (not in the CLI) so a fixture can drive the real decision path without cmux, gh, or a
    box: `Evidence` is built by the caller, and every field it needs is one the row already carries.
    """
    out = []
    for row in rows:
        ev = row if isinstance(row, Evidence) else Evidence(
            lane=row.get("lane", ""),
            turn=row.get("turn"),
            last_text=row.get("last_text", "") or "",
            ask_signal=row.get("ask_signal", "") or "",
            lane_verdict=row.get("verdict", "") or "",
            child_state=row.get("child_state", "") or "",
            steerable=row.get("steerable"),
            boot_prompt=row.get("boot_prompt"),
            model_retry=row.get("model_retry"),
            # ⛔ THE PRODUCER'S OWN KEY (round 4, #4046 P2). `lane-status.py` emits the in-flight call
            # as a DICT under `tool` (`lane-status.py:1533` `dict(name=…, timeout=…, age=…)`, set at
            # `:2439`); it never emits `tool_in_flight`. Reading only the invented key meant the
            # expired-budget branch (`triage.py`'s `tool_budget_read and not tool_budget_open`) was
            # UNREACHABLE through this function — the same producer-key-set defect the round-3 commit
            # fixed in `lane-route.evidence_for`, left standing here. Nothing in production called
            # `route_rows`, which is exactly why it went unnoticed; the suite now drives it.
            tool_in_flight=_tool_in_flight(row),
            tool_budget_open=_tool_budget_open(row),
            tool_budget_read=_tool_budget_read(row),
        )
        r = route(ev)
        d = r.as_dict()
        d["lane"] = ev.lane
        out.append(d)
    return out


def may_continue(ev: Evidence) -> tuple:
    """`(may_send_continue, Route)` — the ONE question a nudger has to ask before it types.

    Extracted so the nudge path (`scripts/turn-end.py`) and the suite ask the router the SAME
    question instead of each re-deriving it. A caller that wants to send "continue" MUST gate on the
    first element; the Route comes back too so the caller can record WHAT it decided and why — a
    suppression with no reason is a lane that goes quiet for no visible cause.
    """
    r = route(ev)
    return (r.route == "idle-continue" and r.action == "send-continue"), r


def summary(routes: Sequence[dict]) -> str:
    """One line per route class, for a beat or a log — never a paragraph per lane."""
    counts = {}
    for r in routes:
        key = r["route"] if not r.get("subcase") else "%s:%s" % (r["route"], r["subcase"])
        counts[key] = counts.get(key, 0) + 1
    if not counts:
        return "ROUTE (none)"
    parts = ["%s=%d" % (k, counts[k]) for k in sorted(counts)]
    names = {}
    for r in routes:
        if r["route"] != "none":
            names.setdefault(r["route"], []).append(r.get("lane") or "?")
    detail = "; ".join("%s: %s" % (k, ", ".join(v)) for k, v in names.items())
    return "ROUTE " + " ".join(parts) + ((" — " + detail) if detail else "")
