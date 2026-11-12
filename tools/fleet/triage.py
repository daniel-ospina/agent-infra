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
#   * `question-lane-ack` — the question lane was resolved/created AND its brief landed there AND it
#     carries the research mandate + the USER QUESTIONS PROTOCOL four parts. A question forwarded raw
#     has not been routed.
#   * `child-record` — the child's own record changed (gone, re-dispatched with a new id).
#   * `pane-ready` — the boot prompt is gone and the composer accepts a line.
#   * `commit-or-turn` — a new commit or a new turn exists; a re-dispatch that produced neither did not
#     happen.
#   * `written-reading` — nothing is executed; the artifact is the reading itself (wait/inspect), and
#     the arm must state WHY it is not acting.
PROOFS = {
    "send-continue": "transcript-growth",
    "route-to-question-lane": "question-lane-ack",
    "repair-child": "child-record",
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
# asking"), and it reads only the last paragraph for that reason.
_FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
_ASK_PHRASES = (
    "shall i", "should i", "do you want", "want me to", "would you like",
    "let me know", "say the word", "your call", "which one", "which option",
    "give me the go", "go ahead?", "proceed?", "ready?", "confirm", "approve",
    "tell me if you want", "on to the next", "does that look right",
)

ASKED = "asked"
NOT_ASKED = "not-asked"
UNREAD = "unread"


def last_paragraph(text: str) -> str:
    """The assistant text's last paragraph, with fenced code removed.

    A question mark inside a code block or a quoted tool error is not the lane asking the owner
    anything, and a turn that ends with a pasted stack trace ends with no paragraph of its own — so
    the fence is stripped BEFORE the split, and an empty result is `UNREAD`, never `NOT_ASKED`.
    """
    body = _FENCE_RE.sub("\n\n", text or "")
    parts = [p.strip() for p in re.split(r"\n\s*\n", body) if p.strip()]
    return parts[-1] if parts else ""


def asks_owner(text: str) -> str:
    """Does this assistant message END by asking the OWNER something? `asked | not-asked | unread`.

    `unread` is a first-class answer, and the caller must treat it as "not proven clean" — the same
    discipline `liveness.py` applies to an unreadable turn boundary. An empty or unparseable read
    cannot be read as `not-asked`, because that reading is the one that licenses the harmful message.
    """
    para = last_paragraph(text)
    if not para:
        return UNREAD
    low = " ".join(para.lower().split())
    if para.rstrip().endswith("?"):
        return ASKED
    for phrase in _ASK_PHRASES:
        if phrase in low:
            # A phrase alone is not the ending — "I asked whether the option was viable" is a
            # statement ABOUT a question. Require it to sit in the final two sentences.
            tail = " ".join(re.split(r"(?<=[.!?])\s+", low)[-2:])
            if phrase in tail:
                return ASKED
    return NOT_ASKED


# ── evidence and route ──────────────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Evidence:
    """Everything the route decision may read. Each field has exactly ONE owner.

    ``turn``            — ``liveness.Turn`` from ``turn_from_jsonl`` (#1254). The ONLY source of
                          "positively open"; `None` means the boundary could not be read.
    ``last_text``       — the last assistant message's text, from the same tail read.
    ``ask_signal``      — ``asked``/``not-asked``/``unread``. Supplied by a caller that ran the Jev
                          classifier, else computed from ``last_text`` by ``asks_owner``. A supplied
                          ``asked`` is NEVER downgraded; a supplied ``not-asked`` is NOT allowed to
                          overrule a mechanical ``asked`` (the harm is one-directional).
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
    if supplied in (NOT_ASKED, UNREAD):
        return supplied
    return mech


def route(ev: Evidence) -> Route:
    """Decide the lane's ROUTE. Total, pure, and ordered by the precedence safety property.

    The order of the checks below IS the contract. Do not reorder them to make a case read better:
    each inversion has a measured harm, named in the module docstring.
    """
    ask = _question(ev)

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
                     evidence="lane-status verdict=%r" % (ev.lane_verdict,))

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

    if ev.model_retry:
        sc = "model-retry"
        return Route(route="wedged", subcase=sc, action=REMEDIES[sc], proof=PROOFS[REMEDIES[sc]],
                     reason="the transcript shows the lane retrying the model, not progressing",
                     evidence="model_retry=True")

    if ev.tool_in_flight:
        # In flight with NO declared budget still open: nothing proves it late either. `wait` — the
        # subcase exists so that "I saw a tool" can never become "kill it".
        sc = "tool-in-flight"
        return Route(route="wedged", subcase=sc, action=REMEDIES[sc], proof=PROOFS[REMEDIES[sc]],
                     reason="a tool is in flight and its budget is not readable — not late on evidence",
                     evidence="tool_budget_open=False")

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

    # ── 4. none — everything still working, or nothing readable ─────────────────────────────────
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
            tool_in_flight=bool(row.get("tool_in_flight")),
            tool_budget_open=bool(row.get("tool_budget_open")),
        )
        r = route(ev)
        d = r.as_dict()
        d["lane"] = ev.lane
        out.append(d)
    return out


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
